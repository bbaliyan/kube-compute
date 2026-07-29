# SPDX-License-Identifier: Apache-2.0
output "server_token" {
  description = "Shared secret used to join a server to the cluster. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.server_token
  sensitive   = true
}

output "agent_token" {
  description = "Shared secret accepted only from agents. Re-exported from the shared cluster-facts core. azure-control-plane needs the raw value for its own server-init node-bootstrap call; azure-node-pool never needs it directly (it reads via Key Vault + its own managed identity instead)."
  value       = module.cluster_facts.agent_token
  sensitive   = true
}

output "k8s_version" {
  description = "K8s distro version every unit in this cluster should install. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.k8s_version
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault holding the agent join token. azure-node-pool's own role assignment is scoped under this vault at the individual-secret level."
  value       = azurerm_key_vault.cluster.id
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the agent join token (used to build the vault URI in azure-node-pool's agent_token_fetch_command)."
  value       = azurerm_key_vault.cluster.name
}

output "agent_token_secret_name" {
  description = "Name of the Key Vault secret holding the agent join token ('agent-token'). azure-node-pool's managed identity is granted read access scoped to exactly this secret."
  value       = azurerm_key_vault_secret.agent_token.name
}

output "cluster_asg_id" {
  description = "ID of the cluster-wide Application Security Group. Both azure-control-plane's own NICs and azure-node-pool's worker NICs join this by id."
  value       = azurerm_application_security_group.cluster.id
}
