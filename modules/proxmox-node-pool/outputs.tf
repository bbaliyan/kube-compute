# SPDX-License-Identifier: Apache-2.0

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (Proxmox = direct SSH to the node)."
  value       = "proxmox"
}

output "worker_node_refs" {
  description = "Map of worker VM name -> {instance_id, ip, provider}."
  value = {
    for k, vm in proxmox_virtual_environment_vm.worker :
    "${var.cluster_name}-${var.pool_name}-${k}" => {
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
