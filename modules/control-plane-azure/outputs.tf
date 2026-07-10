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

output "bootstrap_status_ref" {
  description = "Genesis VM resource ID used to read bootstrap status. Usage: az vm run-command invoke --ids <this> --command-id RunShellScript --scripts 'cat /var/log/kube-compute/bootstrap-status'"
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
  description = "K8s distro version installed on this control plane's control-plane nodes. Wire node-pool-azure's control_plane_k8s_version to this output so the version-skew guard is enforced automatically."
  value       = local.k8s_version
}

# ---- Join flow: consumed by node-pool-azure ----
output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API: null for control_plane_count = 1 (no endpoint at all), the internal Standard LB's frontend private IP otherwise."
  value       = local.registration_address
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault holding the agent join token. node-pool-azure's role assignment is scoped under this vault at the individual-secret level."
  value       = azurerm_key_vault.cluster.id
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the agent join token (used to build the vault URI in node-pool-azure's agent_token_fetch_command)."
  value       = azurerm_key_vault.cluster.name
}

output "agent_token_secret_name" {
  description = "Name of the Key Vault secret holding the agent join token ('agent-token'). node-pool-azure's managed identity is granted read access scoped to exactly this secret."
  value       = azurerm_key_vault_secret.agent_token.name
}

output "cluster_asg_id" {
  description = "ID of the cluster-wide Application Security Group. node-pool-azure's VM Scale Set NICs join this ASG by id — it never creates or owns the ASG itself."
  value       = azurerm_application_security_group.cluster.id
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

output "rendered_cloud_init" {
  description = "Plaintext rendered cloud-config for the genesis node, passed through from cloud-init. Sensitive — for tests/debugging only."
  value       = module.bootstrap.cloud_init
  sensitive   = true
}

output "rendered_cloud_init_additional" {
  description = "Map of rendered cloud-config for additional control-plane nodes, keyed by index. Sensitive."
  value       = { for k, m in module.bootstrap_additional : k => m.cloud_init }
  sensitive   = true
}
