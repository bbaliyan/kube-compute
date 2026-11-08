# SPDX-License-Identifier: Apache-2.0

locals {
  platform_helm_values_object = merge(
    var.platform_helm_values_object,
    {
      for pool in var.platform_node_group == null ? [] : [var.platform_node_group] :
      "platformNodeSelector" => { "kube-compute.io/node-group" = pool }
    },
  )

  # Ingress runs with the platform, so its pool alone answers on the ingress ports;
  # the control plane keeps only the Kubernetes API.
  control_plane_ingress_ports = var.platform_node_group == null ? var.ingress_ports : [for p in var.ingress_ports : p if p == 6443]
  platform_ingress_ports      = [for p in var.ingress_ports : p if p != 6443]
}

# The pools that run ingress (Traefik, the wildcard record) and so open the
# ingress ports: the platform pool, or every pool when there is none.
locals {
  ingress_pools = [for k in keys(var.node_pools) : k if var.platform_node_group == null || k == var.platform_node_group]
}

# Every VM's firewall admits cluster traffic only from cluster_network_cidr;
# without it the ipset falls back to the genesis node alone, and once the
# firewall is enforced, joining nodes can't reach it.
resource "terraform_data" "cluster_network_cidr_set_for_multi_node" {
  count = var.control_plane_count > 1 || length(var.node_pools) > 0 ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.cluster_network_cidr != null
      error_message = "cluster_network_cidr is required when control_plane_count > 1 or any node pool is set: it is the firewall ipset every node admits cluster traffic from."
    }
  }
}

module "control_plane" {
  source = "../proxmox-control-plane"

  cluster_name                      = var.cluster_name
  trusted_ca_pem                    = var.trusted_ca_pem
  registry_mirror_url               = var.registry_mirror_url
  gitops_platform_enabled           = var.gitops_platform_enabled
  gitops_platform_repo_url_override = var.gitops_platform_repo_url_override
  gitops_platform_revision_override = var.gitops_platform_revision_override
  gitops_workloads_repo_url         = var.gitops_workloads_repo_url
  gitops_workloads_revision         = var.gitops_workloads_revision
  gitops_workloads_path             = var.gitops_workloads_path
  workloads_extra_helm_parameters   = var.workloads_extra_helm_parameters
  workloads_helm_values_object      = var.workloads_helm_values_object
  cluster_type                      = var.cluster_type
  cni                               = var.cni
  cert_mode                         = var.cert_mode
  platform_extra_helm_parameters    = var.platform_extra_helm_parameters
  platform_helm_values_object       = local.platform_helm_values_object
  extra_tags                        = var.extra_tags
  proxmox_node                      = var.proxmox_node
  disk_datastore_id                 = var.disk_datastore_id
  iso_datastore_id                  = var.iso_datastore_id
  cloud_init_upload_mode            = var.cloud_init_upload_mode
  network_bridge                    = var.network_bridge
  vm_cores                          = var.vm_cores
  vm_memory_mb                      = var.vm_memory_mb
  vm_disk_gb                        = var.vm_disk_gb
  vm_cpu_type                       = var.vm_cpu_type
  pool_id                           = var.pool_id
  cpu_units                         = var.cpu_units
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
  ingress_ports                     = local.control_plane_ingress_ports
  manage_wildcard_dns_record        = var.platform_node_group == null
  cluster_domain                    = var.cluster_domain
  cluster_dns_name                  = var.cluster_dns_name
  dns_server_address                = var.dns_server_address
  dns_server_port                   = var.dns_server_port
  dns_transport                     = var.dns_transport
  dns_record_ttl                    = var.dns_record_ttl
  tsig_key_name                     = var.tsig_key_name
  tsig_key_algorithm                = var.tsig_key_algorithm
  tsig_key_secret                   = var.tsig_key_secret

  genesis_apply_manifests = var.genesis_apply_manifests
  extra_server_manifests  = var.extra_server_manifests
  graceful_shutdown       = var.graceful_shutdown
  os_auto_updates         = var.os_auto_updates
  node_name_template      = var.control_plane_node_name_template
  boot_scripts            = var.boot_scripts
}

module "node_pools" {
  source   = "../proxmox-node-pool"
  for_each = var.node_pools

  cluster_name        = var.cluster_name
  pool_name           = each.key
  cluster_agent_token = module.control_plane.cluster_agent_token

  node_taints                = each.value.node_taints
  manage_wildcard_dns_record = contains(local.ingress_pools, each.key)
  allowed_ingress_cidrs      = contains(local.ingress_pools, each.key) ? var.allowed_ingress_cidrs : []
  ingress_ports              = contains(local.ingress_pools, each.key) ? local.platform_ingress_ports : []

  # Cluster-wide by default, overridable per pool. Ternaries rather than coalesce(): both
  # sides are commonly null, and coalesce raises when every argument is null.
  trusted_ca_pem         = each.value.trusted_ca_pem != null ? each.value.trusted_ca_pem : var.trusted_ca_pem
  registry_mirror_url    = each.value.registry_mirror_url != null ? each.value.registry_mirror_url : var.registry_mirror_url
  ssh_authorized_keys    = each.value.ssh_authorized_keys != null ? each.value.ssh_authorized_keys : var.ssh_authorized_keys
  dns_servers            = each.value.dns_servers != null ? each.value.dns_servers : var.dns_servers
  cluster_dns_name       = var.cluster_dns_name
  cluster_domain         = each.value.cluster_domain != null ? each.value.cluster_domain : var.cluster_domain
  dns_server_address     = each.value.dns_server_address != null ? each.value.dns_server_address : var.dns_server_address
  dns_server_port        = each.value.dns_server_port != null ? each.value.dns_server_port : var.dns_server_port
  dns_transport          = each.value.dns_transport != null ? each.value.dns_transport : var.dns_transport
  dns_record_ttl         = each.value.dns_record_ttl != null ? each.value.dns_record_ttl : var.dns_record_ttl
  tsig_key_name          = each.value.tsig_key_name != null ? each.value.tsig_key_name : var.tsig_key_name
  tsig_key_algorithm     = each.value.tsig_key_algorithm != null ? each.value.tsig_key_algorithm : var.tsig_key_algorithm
  tsig_key_secret        = each.value.tsig_key_secret != null ? each.value.tsig_key_secret : var.tsig_key_secret
  proxmox_node           = each.value.proxmox_node
  disk_datastore_id      = each.value.disk_datastore_id
  iso_datastore_id       = each.value.iso_datastore_id
  cloud_init_upload_mode = var.cloud_init_upload_mode
  network_bridge         = each.value.network_bridge
  vm_cores               = each.value.vm_cores
  vm_memory_mb           = each.value.vm_memory_mb
  vm_disk_gb             = each.value.vm_disk_gb
  vm_cpu_type            = each.value.vm_cpu_type
  pool_id                = each.value.pool_id != null ? each.value.pool_id : var.pool_id
  cpu_units              = each.value.cpu_units != null ? each.value.cpu_units : var.cpu_units
  os_image_url           = each.value.os_image_url
  os_image_file_name     = each.value.os_image_file_name
  os_image_file_id       = each.value.os_image_file_id
  proxmox_template_vm_id = each.value.proxmox_template_vm_id
  worker_ip_addresses    = each.value.worker_ip_addresses
  vm_gateway             = each.value.vm_gateway != null ? each.value.vm_gateway : var.vm_gateway
  desired_count          = each.value.desired_count
  registration_address   = each.value.registration_address
  extra_node_labels      = each.value.extra_node_labels
  graceful_shutdown      = var.graceful_shutdown
  os_auto_updates        = var.os_auto_updates
  node_name_template     = each.value.node_name_template
  boot_scripts           = var.boot_scripts
}
