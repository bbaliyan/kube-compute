# SPDX-License-Identifier: Apache-2.0
locals {
  # cluster-facts re-exports these overrides as "" rather than null (OpenTofu
  # drops null-valued root outputs from state entirely, breaking any
  # Terragrunt dependency block referencing them the moment the value is
  # actually null — the common, default case here). node-bootstrap's own
  # pinned-default fallback relies on receiving a genuine Terraform `null`
  # for this module argument (passing "" would set an empty repo URL instead
  # of falling back to the pin), so convert back at this boundary.
  effective_gitops_platform_repo_url_override = var.gitops_platform_repo_url_override != "" ? var.gitops_platform_repo_url_override : null
  effective_gitops_platform_revision_override = var.gitops_platform_revision_override != "" ? var.gitops_platform_revision_override : null

  network_rg = coalesce(var.network_resource_group_name, var.resource_group_name)

  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  create_record = local.has_domain && var.dns_zone_resource_group != null

  control_plane_taint = var.cluster_type == "dedicated_control_plane"
  effective_cni       = coalesce(var.cni, "cilium")
  # Cilium chart default (2 operator replicas, pod anti-affinity) leaves one
  # replica permanently Pending on a genuinely single-node cluster.
  effective_cilium_operator_replicas = var.control_plane_count > 1 ? null : 1

  # OS image: split a user-provided URN (Publisher:Offer:SKU:Version) or default to
  # AlmaLinux 10 gen2, same convention as node-azure.
  image_parts     = var.os_image_urn != null ? split(":", var.os_image_urn) : []
  image_publisher = var.os_image_urn != null ? local.image_parts[0] : "almalinux"
  image_offer     = var.os_image_urn != null ? local.image_parts[1] : "almalinux-x86_64"
  image_sku       = var.os_image_urn != null ? local.image_parts[2] : "10-gen2"
  image_version   = var.os_image_urn != null ? local.image_parts[3] : "latest"

  # Null for control_plane_count = 1 (no registration endpoint); the internal
  # Standard LB's dynamic private frontend IP otherwise (see Task 5).
  registration_address = var.control_plane_count == 1 ? null : try(azurerm_lb.control_plane[0].frontend_ip_configuration[0].private_ip_address, null)

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })
}

# ---- Application Security Groups: the Azure equivalent of AWS's self-referencing SG ----
# The cluster-wide ASG (var.cluster_asg_id) now lives in azure-cluster-facts — both this
# module's own NICs and azure-node-pool's worker NICs join it by id. Only the etcd ASG,
# which azure-node-pool never joins, stays owned here.
resource "azurerm_application_security_group" "etcd" {
  name                = "asg-${var.cluster_name}-etcd"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

# ---- Node-scoped NSG — the module owns only this; VNet/subnet are never touched ----
resource "azurerm_network_security_group" "control_plane" {
  name                = "nsg-${var.cluster_name}-cp"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

# SSH is always denied, at the highest priority (lowest number), regardless of ingress_ports.
# Out-of-band access is via `az vm run-command invoke` — no inbound port required.
resource "azurerm_network_security_rule" "deny_ssh" {
  name                        = "deny-ssh"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.control_plane.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

# East-west, cluster-wide: any protocol/port among members of the cluster ASG. Priority 110
# sits between deny-ssh (100) and the CIDR-based allow_inbound rules (200+) so it always wins
# over an accidental narrower rule, and never collides regardless of how many ingress_ports
# are configured.
resource "azurerm_network_security_rule" "cluster_self" {
  name                                       = "allow-cluster-self"
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.control_plane.name
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  source_application_security_group_ids      = [var.cluster_asg_id]
  destination_application_security_group_ids = [var.cluster_asg_id]
}

# etcd (2379-2380) is control-plane-to-control-plane only, via the separate etcd ASG that
# azure-node-pool never joins.
resource "azurerm_network_security_rule" "etcd_peer" {
  name                                       = "allow-etcd-peer"
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.control_plane.name
  priority                                   = 115
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = "2379-2380"
  source_application_security_group_ids      = [azurerm_application_security_group.etcd.id]
  destination_application_security_group_ids = [azurerm_application_security_group.etcd.id]
}

# One allow rule per port, accepting traffic from all allowed_ingress_cidrs. Priorities:
# 200, 210, 220 ... — above cluster_self/etcd_peer (110/115) so those unconditional
# cluster-membership allows are never shadowed.
resource "azurerm_network_security_rule" "allow_inbound" {
  for_each = {
    for idx, port in var.ingress_ports :
    tostring(port) => { port = port, priority = 200 + idx * 10 }
  }

  name                        = "allow-${each.key}"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.control_plane.name
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefixes     = var.allowed_ingress_cidrs
  destination_address_prefix  = "*"
}

# ---- Control-plane NICs, one per index 0..control_plane_count-1 ----
resource "azurerm_network_interface" "control_plane" {
  for_each = { for i in range(var.control_plane_count) : tostring(i) => i }

  name                = "nic-${var.cluster_name}-cp-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.control_plane.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "control_plane" {
  for_each = azurerm_network_interface.control_plane

  network_interface_id      = each.value.id
  network_security_group_id = azurerm_network_security_group.control_plane.id
}

resource "azurerm_network_interface_application_security_group_association" "cluster" {
  for_each = azurerm_network_interface.control_plane

  network_interface_id          = each.value.id
  application_security_group_id = var.cluster_asg_id
}

resource "azurerm_network_interface_application_security_group_association" "etcd" {
  for_each = azurerm_network_interface.control_plane

  network_interface_id          = each.value.id
  application_security_group_id = azurerm_application_security_group.etcd.id
}

# ---- The genesis control-plane node (server-init) ----
# on_node invocation: node-bootstrap renders a self-contained bundle we deliver
# via az vm run-command (azurerm_virtual_machine_run_command below). Ansible runs
# on the node itself (-c local); no inbound port, so the deny-ssh NSG rule stays.
module "bootstrap" {
  source = "../node-bootstrap"

  invocation_mode                = "on_node"
  ansible_playbook_path          = var.ansible_playbook_path
  cluster_name                   = var.cluster_name
  node_name                      = "${var.cluster_name}-cp-0"
  k8s_version                    = var.k8s_version
  cluster_fqdn                   = local.cluster_fqdn
  cluster_fqdn_suffix            = local.fqdn_suffix
  node_role                      = "server-init"
  control_plane_taint            = local.control_plane_taint
  cni                            = local.effective_cni
  cilium_operator_replicas       = local.effective_cilium_operator_replicas
  cluster_token                  = var.cluster_token
  cluster_agent_token            = var.cluster_agent_token
  registration_address           = local.registration_address
  extra_tls_sans                 = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  trusted_ca_pem                 = var.trusted_ca_pem
  registry_mirror_url            = var.registry_mirror_url
  gitops_platform_enabled        = var.gitops_platform_enabled
  gitops_platform_repo_url       = local.effective_gitops_platform_repo_url_override
  gitops_platform_revision       = local.effective_gitops_platform_revision_override
  gitops_workloads_repo_url      = var.gitops_workloads_repo_url
  gitops_workloads_revision      = var.gitops_workloads_revision
  gitops_workloads_path          = var.gitops_workloads_path
  cert_mode                      = var.cert_mode
  platform_extra_helm_parameters = var.platform_extra_helm_parameters
  platform_helm_values_object    = var.platform_helm_values_object
  extra_tags                     = var.extra_tags
}

resource "azurerm_linux_virtual_machine" "control_plane" {
  name                            = "vm-${var.cluster_name}-cp-0"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.control_plane["0"].id]
  zone                            = tostring(var.availability_zones[0])
  tags                            = merge(local.common_tags, { Role = "control-plane" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = local.image_publisher
    offer     = local.image_offer
    sku       = local.image_sku
    version   = local.image_version
  }

  # No custom_data: bootstrap runs post-boot via az vm run-command (on_node), not
  # cloud-init. The VM only needs the Azure Linux Guest Agent, which the image ships.

  lifecycle {
    precondition {
      condition     = var.control_plane_count == 1 || length(distinct(var.availability_zones)) >= 3
      error_message = "control_plane_count > 1 requires at least 3 distinct availability_zones (got ${length(distinct(var.availability_zones))})."
    }
  }
}

# ---- Additional control-plane nodes (2..N): server-join ----
module "bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../node-bootstrap"

  invocation_mode          = "on_node"
  ansible_playbook_path    = var.ansible_playbook_path
  cluster_name             = var.cluster_name
  node_name                = "${var.cluster_name}-cp-${each.key}"
  k8s_version              = var.k8s_version
  cluster_fqdn             = local.cluster_fqdn
  cluster_fqdn_suffix      = local.fqdn_suffix
  node_role                = "server-join"
  control_plane_taint      = local.control_plane_taint
  cni                      = local.effective_cni
  cilium_operator_replicas = local.effective_cilium_operator_replicas
  registration_address     = local.registration_address
  extra_tls_sans           = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  cluster_token            = var.cluster_token
  trusted_ca_pem           = var.trusted_ca_pem
  registry_mirror_url      = var.registry_mirror_url
  cert_mode                = var.cert_mode
  extra_tags               = var.extra_tags
  # gitops_* intentionally omitted: Argo/platform bootstrap runs on the first server only.
}

resource "azurerm_linux_virtual_machine" "control_plane_additional" {
  for_each = module.bootstrap_additional

  name                            = "vm-${var.cluster_name}-cp-${each.key}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.control_plane[each.key].id]
  zone                            = tostring(var.availability_zones[tonumber(each.key) % length(var.availability_zones)])
  tags                            = merge(local.common_tags, { Role = "control-plane" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = local.image_publisher
    offer     = local.image_offer
    sku       = local.image_sku
    version   = local.image_version
  }

  # No custom_data — bootstrap is delivered via run-command (see below).

  depends_on = [azurerm_linux_virtual_machine.control_plane]
}

# ---- Bootstrap delivery: az vm run-command, one per control-plane node ----
# The portless Azure transport (constraint 6): run-command pushes node-bootstrap's
# self-contained on_node bundle and Ansible runs on the node. Secrets travel as
# protected parameters, which Azure's Linux guest agent injects as environment
# variables named exactly as each parameter — the names node-bootstrap's runner
# reads (CLUSTER_TOKEN, CLUSTER_AGENT_TOKEN, TRUSTED_CA_PEM, ...). keys() is
# non-secret (fixed names); only the values are sensitive.
#
# NOTE (pending real-apply verification — Azure is untested here): two
# assumptions ride on this — (1) managed run-command runs on the AlmaLinux 10
# image (waagent >= 2.4.0.2; AL10 is not in Microsoft's support table), and
# (2) protected-parameter names surface verbatim as env vars on Linux. Both must
# be confirmed on a real apply before this path is trusted. Full-log streaming to
# an output blob is deliberately deferred to a separate ticket; until then the
# captured output view is the last-4KB instanceView (the script still runs fully).
resource "azurerm_virtual_machine_run_command" "genesis" {
  name               = "kube-compute-bootstrap"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.control_plane.id

  source {
    script = module.bootstrap.on_node_bundle
  }

  dynamic "protected_parameter" {
    for_each = nonsensitive(toset(keys(module.bootstrap.on_node_secret_env)))
    content {
      name  = protected_parameter.value
      value = module.bootstrap.on_node_secret_env[protected_parameter.value]
    }
  }
}

# Deliberately NOT depends_on azurerm_virtual_machine_run_command.genesis: that forced
# every additional server's run-command (OS-prep/RKE2-install, delivered via the same
# on_node bundle as genesis) to wait for genesis's entire bootstrap script, including
# genesis's post-Ready GitOps/Argo CD bootstrap — unrelated to etcd join safety. Mirrors
# aws-node-pool's established no-depends_on precedent: RKE2's server process retries
# its `server:` line the same way its agent process retries a worker's join target, so
# a sibling's run-command executing concurrently with genesis's just waits out
# genesis's install via that connection retry. Ordering *among* the additional nodes
# themselves (one non-voting etcd learner at a time) remains handled by node-bootstrap's
# own staggered, self-healing join-race retry.
resource "azurerm_virtual_machine_run_command" "additional" {
  for_each = module.bootstrap_additional

  name               = "kube-compute-bootstrap"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.control_plane_additional[each.key].id

  source {
    script = each.value.on_node_bundle
  }

  dynamic "protected_parameter" {
    for_each = nonsensitive(toset(keys(each.value.on_node_secret_env)))
    content {
      name  = protected_parameter.value
      value = each.value.on_node_secret_env[protected_parameter.value]
    }
  }
}

# ---- Internal Standard LB fronting the control plane on 6443 (control_plane_count > 1) ----
# A floating VIP is impossible on Azure (a private IP is subnet-scoped, and Azure VNets are
# not flat L2 across zones any more than AWS VPCs are across AZs) — an internal Standard LB
# is the only registration-endpoint primitive here, matching aws-control-plane's NLB.
resource "azurerm_lb" "control_plane" {
  count               = var.control_plane_count > 1 ? 1 : 0
  name                = "lb-${var.cluster_name}-cp"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = local.common_tags

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.control_plane.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_lb_backend_address_pool" "control_plane" {
  count           = var.control_plane_count > 1 ? 1 : 0
  loadbalancer_id = azurerm_lb.control_plane[0].id
  name            = "cp-backend"
}

resource "azurerm_lb_probe" "control_plane" {
  count               = var.control_plane_count > 1 ? 1 : 0
  loadbalancer_id     = azurerm_lb.control_plane[0].id
  name                = "cp-probe"
  protocol            = "Tcp"
  port                = 6443
  interval_in_seconds = 10
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "control_plane" {
  count                          = var.control_plane_count > 1 ? 1 : 0
  loadbalancer_id                = azurerm_lb.control_plane[0].id
  name                           = "cp-6443"
  protocol                       = "Tcp"
  frontend_port                  = 6443
  backend_port                   = 6443
  frontend_ip_configuration_name = "internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.control_plane[0].id]
  probe_id                       = azurerm_lb_probe.control_plane[0].id
}

resource "azurerm_network_interface_backend_address_pool_association" "control_plane" {
  for_each = var.control_plane_count > 1 ? azurerm_network_interface.control_plane : {}

  network_interface_id    = each.value.id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.control_plane[0].id
}

# ---- Optional: wildcard A record in an Azure DNS zone you already own ----
resource "azurerm_dns_a_record" "wildcard" {
  count               = local.create_record ? 1 : 0
  name                = "*.${var.cluster_name}"
  resource_group_name = var.dns_zone_resource_group
  zone_name           = var.cluster_domain
  ttl                 = 60
  records             = [var.control_plane_count == 1 ? azurerm_network_interface.control_plane["0"].private_ip_address : local.registration_address]
  tags                = local.common_tags
}
