# SPDX-License-Identifier: Apache-2.0
output "instance_ids" {
  description = "Resource IDs of every worker VM in this pool, keyed by index. Control-plane verb-scripts target these via az vm run-command."
  value       = { for k, vm in azurerm_linux_virtual_machine.worker : k => vm.id }
}

output "private_ips" {
  description = "Private IPv4 address of every worker in this pool, keyed by index."
  value       = { for k, nic in azurerm_network_interface.worker : k => nic.private_ip_address }
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (Azure = az vm run-command, per VM)."
  value       = "azure"
}

output "zone" {
  description = "Availability zone this pool is pinned to."
  value       = var.zone
}

output "worker_identity_principal_ids" {
  description = "Principal ID of each worker's system-assigned managed identity, keyed by index. Reference these to grant additional least-privilege role assignments from your consumer repo."
  value       = { for k, vm in azurerm_linux_virtual_machine.worker : k => vm.identity[0].principal_id }
}

output "rendered_bootstrap_bundle" {
  description = "The node-bootstrap on_node runner script delivered to each worker via run-command, keyed by index. Carries no secrets (those flow as protected parameters). For tests/debugging only."
  value       = { for k, m in module.bootstrap : k => m.on_node_bundle }
}
