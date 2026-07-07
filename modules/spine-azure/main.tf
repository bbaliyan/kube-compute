# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../node-bootstrap/templates/cloud-init-ubuntu-2604.yaml.tpl")

  network_rg = coalesce(var.network_resource_group_name, var.resource_group_name)

  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  create_record = local.has_domain && var.dns_zone_resource_group != null

  control_plane_taint              = var.cluster_type == "dedicated_control_plane"
  effective_cni                    = var.cni != null ? var.cni : (var.control_plane_count > 1 ? "cilium" : "flannel")
  effective_etcd_snapshots_enabled = var.etcd_snapshots_enabled != null ? var.etcd_snapshots_enabled : var.control_plane_count > 1

  # Kv name: 24-char Azure limit, globally unique — 18 chars of cluster_name (hyphens
  # stripped; Key Vault names are alphanumeric-and-hyphen but a plain alnum body keeps this
  # simple) + a 6-char random suffix = 24 exactly.
  kv_name = "${substr("kv${replace(var.cluster_name, "-", "")}", 0, 18)}${random_string.kv_suffix.result}"

  # OS image: split a user-provided URN (Publisher:Offer:SKU:Version) or default to
  # Ubuntu 26.04 LTS gen2, same convention as node-azure.
  image_parts     = var.os_image_urn != null ? split(":", var.os_image_urn) : []
  image_publisher = var.os_image_urn != null ? local.image_parts[0] : "Canonical"
  image_offer     = var.os_image_urn != null ? local.image_parts[1] : "ubuntu-26_04-lts"
  image_sku       = var.os_image_urn != null ? local.image_parts[2] : "server-gen2"
  image_version   = var.os_image_urn != null ? local.image_parts[3] : "latest"

  # Null for control_plane_count = 1 (no registration endpoint — ADR 0003); the internal
  # Standard LB's dynamic private frontend IP otherwise (see Task 5).
  registration_address = var.control_plane_count == 1 ? null : try(azurerm_lb.control_plane[0].frontend_ip_configuration[0].private_ip_address, null)

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-node"
  })
}

# ---- Join-token flow: pre-generated so a spine + pool join in one apply pass ----
# Two tokens, least privilege: the server token grants joining etcd/control-plane (embedded
# directly into this spine's own node-bootstrap calls — control-plane nodes never fetch
# anything from Key Vault); the agent token is all a worker ever receives, delivered via
# Key Vault + managed identity (ADR 0004's Azure answer) so a compromised worker cannot
# rejoin as a control-plane/etcd member.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}

resource "random_string" "kv_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---- Key Vault: RBAC authorization, agent token only ----
resource "azurerm_key_vault" "cluster" {
  name                       = local.kv_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  tags                       = local.common_tags
}

# RBAC authorization grants nothing implicitly — the executing principal needs an explicit
# role to write the secret below. NOTE: Azure role assignments are eventually consistent
# (documented propagation delay of up to a few minutes); a first `tofu apply` immediately
# after vault creation may need to be re-run if the secret write races this assignment. See
# README for the operator-facing version of this note.
resource "azurerm_role_assignment" "kv_admin_self" {
  scope                = azurerm_key_vault.cluster.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "agent_token" {
  name         = "agent-token"
  value        = random_password.agent_token.result
  key_vault_id = azurerm_key_vault.cluster.id
  tags         = local.common_tags

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

# ---- Application Security Groups: the Azure equivalent of AWS's self-referencing SG ----
resource "azurerm_application_security_group" "cluster" {
  name                = "asg-${var.cluster_name}-cluster"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

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
  source_application_security_group_ids      = [azurerm_application_security_group.cluster.id]
  destination_application_security_group_ids = [azurerm_application_security_group.cluster.id]
}

# etcd (2379-2380) is control-plane-to-control-plane only, via the separate etcd ASG that
# worker-pool-azure never joins.
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
  application_security_group_id = azurerm_application_security_group.cluster.id
}

resource "azurerm_network_interface_application_security_group_association" "etcd" {
  for_each = azurerm_network_interface.control_plane

  network_interface_id          = each.value.id
  application_security_group_id = azurerm_application_security_group.etcd.id
}

# ---- The genesis control-plane node (server-init) ----
module "bootstrap" {
  source = "../node-bootstrap"

  cloud_init_template            = local.cloud_init_template
  cluster_name                   = var.cluster_name
  k8s_version                    = var.k8s_version
  cluster_fqdn                   = local.cluster_fqdn
  node_role                      = "server-init"
  control_plane_taint            = local.control_plane_taint
  cni                            = local.effective_cni
  cluster_token                  = random_password.server_token.result
  cluster_agent_token            = random_password.agent_token.result
  registration_address           = local.registration_address
  extra_tls_sans                 = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  etcd_snapshot_enabled          = local.effective_etcd_snapshots_enabled
  etcd_snapshot_schedule_cron    = var.etcd_snapshot_schedule_cron
  etcd_snapshot_retention        = var.etcd_snapshot_retention
  trusted_ca_pem                 = var.trusted_ca_pem
  registry_mirror_url            = var.registry_mirror_url
  gitops_platform_repo_url       = var.gitops_platform_repo_url
  gitops_platform_revision       = var.gitops_platform_revision
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

  custom_data = module.bootstrap.user_data_base64

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

  cloud_init_template         = local.cloud_init_template
  cluster_name                = var.cluster_name
  k8s_version                 = var.k8s_version
  cluster_fqdn                = local.cluster_fqdn
  node_role                   = "server-join"
  control_plane_taint         = local.control_plane_taint
  cni                         = local.effective_cni
  registration_address        = local.registration_address
  extra_tls_sans              = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  etcd_snapshot_enabled       = local.effective_etcd_snapshots_enabled
  etcd_snapshot_schedule_cron = var.etcd_snapshot_schedule_cron
  etcd_snapshot_retention     = var.etcd_snapshot_retention
  cluster_token               = random_password.server_token.result
  trusted_ca_pem              = var.trusted_ca_pem
  registry_mirror_url         = var.registry_mirror_url
  cert_mode                   = var.cert_mode
  extra_tags                  = var.extra_tags
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

  custom_data = each.value.user_data_base64

  depends_on = [azurerm_linux_virtual_machine.control_plane]
}

# ---- Internal Standard LB fronting the control plane on 6443 (control_plane_count > 1) ----
# A floating VIP is impossible on Azure (a private IP is subnet-scoped, and Azure VNets are
# not flat L2 across zones any more than AWS VPCs are across AZs) — an internal Standard LB
# is the only registration-endpoint primitive here, matching spine-aws's NLB and ADR 0003.
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
