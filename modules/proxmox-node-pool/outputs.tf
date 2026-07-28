# SPDX-License-Identifier: Apache-2.0

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (Proxmox = direct SSH to the node)."
  value       = "proxmox"
}

output "worker_node_refs" {
  description = "Map of worker VM name -> {instance_id, ip, provider}."
  value = {
    for k, vm in proxmox_virtual_environment_vm.worker :
    "${var.cluster_name}-worker-${k}" => {
      instance_id = tostring(vm.vm_id)
      ip          = local.worker_ips[k]
      provider    = "proxmox"
    }
  }
}

output "wildcard_dns_registration_enabled" {
  description = "Whether this pool actually published *.<cluster_name> to a DNS server via dns-registration (true only when both cluster_domain and dns_server_address were set). Relevant on a dedicated_control_plane cluster, where this pool (not the control plane) owns the wildcard record — see proxmox-control-plane's wildcard_registration_enabled output for the all_in_one case."
  value       = local.dns_registration_enabled
}
