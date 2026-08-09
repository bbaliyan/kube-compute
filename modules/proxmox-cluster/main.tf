# SPDX-License-Identifier: Apache-2.0

locals {
  # Same formula as proxmox-control-plane's/proxmox-node-pool's own
  # identical local — needed here too because this module now owns the
  # dns provider both of them used to self-configure (see Task 3b).
  tsig_key_name_fqdn = "${trimsuffix(coalesce(var.tsig_key_name, "unused"), ".")}."

  # kube-platform's own bootstrap chart gates deploying the cluster-autoscaler
  # Argo CD Application on this Helm value (bootstrap/templates/
  # cluster-autoscaler-app.yaml) — this module is the one that actually owns
  # cluster_autoscaler_enabled, so it injects the parameter via
  # node-bootstrap's existing generic platform_extra_helm_parameters map
  # (see node-bootstrap/main.tf's platform_app_yaml local for why the
  # dedicated hardcoded parameter was removed there).
  platform_extra_helm_parameters = merge(
    var.platform_extra_helm_parameters,
    { clusterAutoscalerEnabled = tostring(var.cluster_autoscaler_enabled) },
  )

  # ---- cluster-autoscaler-workers.yaml (Cluster + Secret + ProxmoxMachineTemplate + MachineDeployment) ----
  # See templates/cluster-autoscaler-workers.yaml.tftpl for field-source
  # commentary. vm_memory_mb -> memoryMiB unit mismatch (research spike §3):
  # ProxmoxMachineTemplate wants MiB, this module's/proxmox-node-pool's own
  # convention is MB, so the conversion happens here, not in the template.
  cluster_autoscaler_bundle_yaml = !var.cluster_autoscaler_enabled ? "" : templatefile(
    "${path.module}/templates/cluster-autoscaler-workers.yaml.tftpl",
    {
      cluster_name           = var.cluster_name
      min_size               = var.cluster_autoscaler_worker_min_size
      max_size               = var.cluster_autoscaler_worker_max_size
      vm_cores               = var.cluster_autoscaler_worker_template.vm_cores
      vm_memory_mib          = ceil(var.cluster_autoscaler_worker_template.vm_memory_mb * 1000000 / 1048576)
      vm_disk_gb             = var.cluster_autoscaler_worker_template.vm_disk_gb
      proxmox_node           = var.cluster_autoscaler_worker_template.proxmox_node
      proxmox_template_vm_id = var.cluster_autoscaler_worker_template.proxmox_template_vm_id
      disk_datastore_id      = var.cluster_autoscaler_worker_template.disk_datastore_id
      network_bridge         = var.cluster_autoscaler_worker_template.network_bridge
      bootstrap_secret_b64   = var.cluster_autoscaler_enabled ? base64encode(module.cluster_autoscaler_worker_bootstrap[0].cloud_init_user_data) : ""
    }
  )

  genesis_apply_manifests = !var.cluster_autoscaler_enabled ? [] : [{
    path    = "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    content = local.cluster_autoscaler_bundle_yaml
  }]

  # Deliberately NOT module.control_plane.cluster_fqdn/cluster_ip: this
  # bundle's Secret is written into the CONTROL PLANE's own cloud-init
  # (genesis_apply_manifests, below), so if this module's registration
  # address referenced either of those two outputs, it would create a
  # dependency cycle — cluster_ip in particular resolves from the
  # control-plane VM resource itself, which needs its own cloud-init (the
  # thing this bundle feeds into) rendered first. Instead this mirrors
  # proxmox-node-pool's own default exactly (see that module's
  # registration_address variable doc): the genesis node's single-target
  # self-registered DNS name, computed here from this module's own
  # cluster_domain/dns_server_address variables, no control_plane output
  # involved. Requires DNS registration to be configured (both variables
  # set) — validated below. cluster_fqdn (the round-robin api.* record) is
  # deliberately avoided even where it wouldn't cycle, per that same
  # variable's doc: round-robin causes 10-20+ minute join hangs.
  cluster_autoscaler_registration_address = var.cluster_domain != null && var.dns_server_address != null ? (
    "genesis.${var.cluster_name}.${trimsuffix(var.cluster_domain, ".")}"
  ) : null
}

# Shared worker cloud-init payload for every CAPI-provisioned autoscaler
# Machine: rendered once, referenced by every MachineDeployment replica via
# the same Secret (Machine.spec.bootstrap.dataSecretName) — not a full
# node-bootstrap instantiation per replica the way proxmox-node-pool's own
# static workers get one each, since CAPMOX/cluster-autoscaler (not this
# module) creates the actual VMs. set_hostname = false: this payload is
# shared byte-for-byte across every replica, so it cannot carry a
# node-unique hostname — see node-bootstrap's set_hostname variable for the
# still-unverified assumption this relies on (CAPMOX's own per-VM cloud-init
# metadata supplying a usable hostname instead). node_name is still required
# by node-bootstrap's interface even though set_hostname = false means it is
# never written into cloud-config: purely a Terraform-internal label here,
# not a real hostname, so it does not need to be unique on disk.
# agent_token_fetch_command mirrors proxmox-node-pool's own module
# "node_bootstrap" call exactly (see that module's identical local) — every
# worker replica in a pool already gets byte-identical values for it, which
# is exactly why a single shared render works for CAPI-provisioned replicas
# too. cluster_agent_token itself is safe to read from module.control_plane
# here (unlike cluster_fqdn/cluster_ip) — it comes from a random_password
# resource with no dependency on the control plane's own cloud-init render.
module "cluster_autoscaler_worker_bootstrap" {
  source = "../node-bootstrap"
  count  = var.cluster_autoscaler_enabled ? 1 : 0

  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-autoscaler-worker"
  node_role                 = "worker"
  set_hostname              = false
  registration_address      = local.cluster_autoscaler_registration_address
  agent_token_fetch_command = "echo '${module.control_plane.cluster_agent_token}'"
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  dns_servers               = var.dns_servers
}

# Module calls don't support lifecycle preconditions (only resources/data
# sources do). A plain `check` block only warns, not blocks, at apply time
# (real gap: a misconfigured cluster_autoscaler_enabled = true would apply
# cleanly with a broken join address baked into every worker's Secret,
# discoverable only in a warning scrolled past during apply). terraform_data
# is a real, provider-less resource that DOES support lifecycle
# preconditions, so it's used here purely to get a hard-stop precondition,
# matching proxmox-node-pool's own registration_address precondition in
# strictness even though this module has no other resources of its own to
# attach one to.
resource "terraform_data" "cluster_autoscaler_registration_address_configured" {
  count = var.cluster_autoscaler_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.cluster_autoscaler_registration_address != null
      error_message = "cluster_autoscaler_enabled = true requires both cluster_domain and dns_server_address to be set — autoscaled workers join through the genesis node's self-registered DNS name, computed from those two, same as proxmox-node-pool's own default registration_address."
    }
  }
}

module "control_plane" {
  source    = "../proxmox-control-plane"
  providers = { dns = dns }

  ansible_ssh_private_key_file      = var.ansible_ssh_private_key_file
  ansible_ssh_user                  = var.ansible_ssh_user
  cluster_name                      = var.cluster_name
  trusted_ca_pem                    = var.trusted_ca_pem
  registry_mirror_url               = var.registry_mirror_url
  gitops_platform_enabled           = var.gitops_platform_enabled
  gitops_platform_repo_url_override = var.gitops_platform_repo_url_override
  gitops_platform_revision_override = var.gitops_platform_revision_override
  gitops_workloads_repo_url         = var.gitops_workloads_repo_url
  gitops_workloads_revision         = var.gitops_workloads_revision
  gitops_workloads_path             = var.gitops_workloads_path
  cluster_type                      = var.cluster_type
  cni                               = var.cni
  cert_mode                         = var.cert_mode
  platform_extra_helm_parameters    = local.platform_extra_helm_parameters
  platform_helm_values_object       = var.platform_helm_values_object
  extra_tags                        = var.extra_tags
  proxmox_node                      = var.proxmox_node
  disk_datastore_id                 = var.disk_datastore_id
  iso_datastore_id                  = var.iso_datastore_id
  network_bridge                    = var.network_bridge
  vm_cores                          = var.vm_cores
  vm_memory_mb                      = var.vm_memory_mb
  vm_disk_gb                        = var.vm_disk_gb
  vm_cpu_type                       = var.vm_cpu_type
  node_arch                         = var.node_arch
  os_image_url                      = var.os_image_url
  os_image_file_name                = var.os_image_file_name
  os_image_file_id                  = var.os_image_file_id
  proxmox_template_vm_id            = var.proxmox_template_vm_id
  ssh_authorized_keys               = var.ssh_authorized_keys
  dns_servers                       = var.dns_servers
  control_plane_count               = var.control_plane_count
  control_plane_ip_addresses        = var.control_plane_ip_addresses
  vm_gateway                        = var.vm_gateway
  cluster_network_cidr              = var.cluster_network_cidr
  allowed_ingress_cidrs             = var.allowed_ingress_cidrs
  ingress_ports                     = var.ingress_ports
  cluster_domain                    = var.cluster_domain
  dns_server_address                = var.dns_server_address
  dns_server_port                   = var.dns_server_port
  dns_transport                     = var.dns_transport
  dns_record_ttl                    = var.dns_record_ttl
  tsig_key_name                     = var.tsig_key_name
  tsig_key_algorithm                = var.tsig_key_algorithm
  tsig_key_secret                   = var.tsig_key_secret

  genesis_apply_manifests             = local.genesis_apply_manifests
  cluster_autoscaler_crd_wait_enabled = var.cluster_autoscaler_enabled
}

module "node_pools" {
  source    = "../proxmox-node-pool"
  for_each  = var.node_pools
  providers = { dns = dns }

  cluster_name        = var.cluster_name
  cluster_agent_token = module.control_plane.cluster_agent_token

  trusted_ca_pem         = each.value.trusted_ca_pem
  registry_mirror_url    = each.value.registry_mirror_url
  proxmox_node           = each.value.proxmox_node
  disk_datastore_id      = each.value.disk_datastore_id
  iso_datastore_id       = each.value.iso_datastore_id
  network_bridge         = each.value.network_bridge
  vm_cores               = each.value.vm_cores
  vm_memory_mb           = each.value.vm_memory_mb
  vm_disk_gb             = each.value.vm_disk_gb
  vm_cpu_type            = each.value.vm_cpu_type
  os_image_url           = each.value.os_image_url
  os_image_file_name     = each.value.os_image_file_name
  os_image_file_id       = each.value.os_image_file_id
  proxmox_template_vm_id = each.value.proxmox_template_vm_id
  ssh_authorized_keys    = each.value.ssh_authorized_keys
  dns_servers            = each.value.dns_servers
  worker_ip_addresses    = each.value.worker_ip_addresses
  vm_gateway             = each.value.vm_gateway
  desired_count          = each.value.desired_count
  registration_address   = each.value.registration_address
  extra_node_labels      = each.value.extra_node_labels
  cluster_domain         = each.value.cluster_domain
  dns_server_address     = each.value.dns_server_address
  dns_server_port        = each.value.dns_server_port
  dns_transport          = each.value.dns_transport
  dns_record_ttl         = each.value.dns_record_ttl
  tsig_key_name          = each.value.tsig_key_name
  tsig_key_algorithm     = each.value.tsig_key_algorithm
  tsig_key_secret        = each.value.tsig_key_secret
}

module "os_patch" {
  source = "../node-os-patch"

  control_plane_node_refs = module.control_plane.control_plane_node_refs
  worker_node_refs        = merge([for p in module.node_pools : p.worker_node_refs]...)
  ssh_user                = module.control_plane.ansible_ssh_user
  ssh_private_key_file    = module.control_plane.ansible_ssh_private_key_file
}
