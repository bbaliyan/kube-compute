# SPDX-License-Identifier: Apache-2.0

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (Proxmox = direct SSH to the node)."
  value       = "proxmox"
}

output "worker_node_refs" {
  description = "Map of worker VM name -> {instance_id, ip, provider}."
  value = {
    for k, vm in proxmox_virtual_environment_vm.worker :
    local.worker_names[k] => {
      instance_id = tostring(vm.vm_id)
      ip          = local.worker_ips[k]
      provider    = "proxmox"
    }
  }
}

output "wildcard_dns_registration_enabled" {
  description = "Whether this pool published *.<cluster_name> at its workers: manage_wildcard_dns_record with both cluster_domain and dns_server_address set."
  value       = local.dns_registration_enabled
}

output "pool_id" {
  description = "Proxmox resource pool the workers join, or null when they join none."
  value       = var.pool_id
}

output "cpu_units" {
  description = "Proxmox CPU weight set on each worker, or null for the Proxmox default."
  value       = var.cpu_units
}

output "cloud_init_upload_mode" {
  description = "How cloud-init snippets are copied to the Proxmox host for the workers, or null for the provider default (stream)."
  value       = var.cloud_init_upload_mode
}
