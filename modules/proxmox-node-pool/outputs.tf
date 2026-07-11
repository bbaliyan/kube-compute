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

output "rendered_cloud_init" {
  description = "Map of rendered cloud-config per worker index. Sensitive — for tests/debugging only."
  value       = { for k, m in module.bootstrap : k => m.cloud_init }
  sensitive   = true
}
