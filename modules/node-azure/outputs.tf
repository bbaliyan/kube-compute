# SPDX-License-Identifier: Apache-2.0

# ---- Standardized outputs (identical names across all provider modules) ----

output "cluster_name" {
  description = "Cluster name passed to the module. Use this to name local kubeconfig files and other client-side resources."
  value       = var.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID. For Azure: the full VM resource ID (/subscriptions/.../virtualMachines/<name>)."
  value       = azurerm_linux_virtual_machine.node.id
}

output "cluster_ip" {
  description = "Private IP of the K3s node. Known at plan time for static IPs; populated after VM creation for dynamic (DHCP). Register your DNS wildcard at this address."
  value       = var.vm_private_ip != null ? var.vm_private_ip : azurerm_network_interface.node.private_ip_address
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given (IP-only)."
  value       = local.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier ('azure'). Control-plane scripts dispatch via az vm run-command invoke for this provider."
  value       = "azure"
}

output "bootstrap_status_ref" {
  description = "Azure VM resource ID used to read bootstrap status. Usage: az vm run-command invoke --ids <this> --command-id RunShellScript --scripts 'cat /var/log/kube-node/bootstrap-status'"
  value       = azurerm_linux_virtual_machine.node.id
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services (e.g. *.bharat.example.com), or null when no cluster_domain was given. Add one wildcard A record pointing at cluster_ip in your DNS."
  value       = local.wildcard_name
}

# ---- Azure-specific extras ----

output "node_arch" {
  description = "CPU architecture as declared by the operator (x86_64 or arm64). Ensure vm_size and os_image_urn match."
  value       = var.node_arch
}

output "resource_group_name" {
  description = "Resource group the VM was created in. Control-plane scripts need this to target az vm run-command."
  value       = var.resource_group_name
}

output "location" {
  description = "Azure region the VM runs in."
  value       = var.location
}
