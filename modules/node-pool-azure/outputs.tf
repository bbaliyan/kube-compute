# SPDX-License-Identifier: Apache-2.0
output "vmss_id" {
  description = "Resource ID of the VM Scale Set backing this pool."
  value       = azurerm_linux_virtual_machine_scale_set.worker.id
}

output "vmss_name" {
  description = "Name of the VM Scale Set backing this pool."
  value       = azurerm_linux_virtual_machine_scale_set.worker.name
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (Azure = az vm run-command, applied per-instance within the scale set)."
  value       = "azure"
}

output "zone" {
  description = "Availability zone this pool is pinned to."
  value       = var.zone
}

output "worker_identity_principal_id" {
  description = "Principal ID of the VM Scale Set's system-assigned managed identity. Reference this to grant additional least-privilege role assignments (e.g. read access to other cluster secrets) from your consumer repo."
  value       = azurerm_linux_virtual_machine_scale_set.worker.identity[0].principal_id
}

output "rendered_cloud_init" {
  description = "Plaintext rendered cloud-config shared by every worker in this pool, passed through from cloud-init. Sensitive — for tests/debugging only."
  value       = module.bootstrap.cloud_init
  sensitive   = true
}
