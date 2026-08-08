# SPDX-License-Identifier: Apache-2.0

locals {
  # Same formula as proxmox-control-plane's/proxmox-node-pool's own
  # identical local — needed here too because this module now owns the
  # dns provider both of them used to self-configure (see Task 3b).
  tsig_key_name_fqdn = "${trimsuffix(coalesce(var.tsig_key_name, "unused"), ".")}."
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
  platform_extra_helm_parameters    = var.platform_extra_helm_parameters
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
