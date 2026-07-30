# SPDX-License-Identifier: Apache-2.0

# ---- Standardized outputs (identical names across all provider modules) ----

output "cluster_name" {
  description = "Cluster name passed to the module."
  value       = var.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID of the genesis control-plane VM."
  value       = azurerm_linux_virtual_machine.control_plane.id
}

output "cluster_ip" {
  description = "Genesis control-plane node's private IP. For control_plane_count > 1, prefer registration_address."
  value       = azurerm_network_interface.control_plane["0"].private_ip_address
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given."
  value       = local.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier ('azure'). Control-plane scripts dispatch via az vm run-command invoke for this provider."
  value       = "azure"
}

output "node_control_ref" {
  description = "Genesis VM resource ID, for control-plane verb-scripts that need a single node reference. Usage: az vm run-command invoke --ids <this> --command-id RunShellScript. Same primitive this module now uses to bootstrap the node (node-bootstrap on_node delivered via az vm run-command)."
  value       = azurerm_linux_virtual_machine.control_plane.id
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services, or null when no cluster_domain was given."
  value       = local.wildcard_name
}

# ---- Azure-specific extras ----

output "node_arch" {
  description = "CPU architecture as declared by the operator."
  value       = var.node_arch
}

output "resource_group_name" {
  description = "Resource group every control-plane resource was created in."
  value       = var.resource_group_name
}

output "location" {
  description = "Azure region the control plane runs in."
  value       = var.location
}

output "k8s_version" {
  description = "K8s distro version installed on this control plane's control-plane nodes. Sourced from the same cluster-facts unit azure-node-pool also consumes, so version-skew between them is prevented by construction."
  value       = var.k8s_version
}

# ---- Join flow: consumed by azure-node-pool ----
output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API: null for control_plane_count = 1 (no endpoint at all), the internal Standard LB's frontend private IP otherwise."
  value       = local.registration_address
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, provider}."
  value = merge(
    {
      "${var.cluster_name}-cp-0" = {
        instance_id = azurerm_linux_virtual_machine.control_plane.id
        provider    = "azure"
      }
    },
    {
      for k, vm in azurerm_linux_virtual_machine.control_plane_additional :
      "${var.cluster_name}-cp-${k}" => {
        instance_id = vm.id
        provider    = "azure"
      }
    }
  )
}

output "rendered_bootstrap_bundle" {
  description = "The node-bootstrap on_node runner script delivered to the genesis node via run-command. Carries no secrets (those flow as protected parameters). For tests/debugging only."
  value       = module.bootstrap.on_node_bundle
}

output "rendered_bootstrap_bundle_additional" {
  description = "Map of node-bootstrap on_node runner scripts for additional control-plane nodes, keyed by index. No secrets. For tests/debugging."
  value       = { for k, m in module.bootstrap_additional : k => m.on_node_bundle }
}
