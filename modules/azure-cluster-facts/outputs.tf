# SPDX-License-Identifier: Apache-2.0
# Output names match azure-control-plane's/azure-node-pool's own variable
# names (cluster_token, gitops_platform_enabled, etc.) rather than the
# neutral names the shared cluster-facts core uses internally — so a
# caller's Terragrunt `inputs` block can pass `dependency.cluster_facts.outputs`
# straight through via merge() instead of remapping every key by hand.
output "cluster_name" {
  description = "Cluster identity, as passed in. Re-exported verbatim so control-plane/node-pool source it from here instead of re-deriving or re-hardcoding it."
  value       = var.cluster_name
}

output "cluster_token" {
  description = "Shared secret used to join a server to the cluster. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.server_token
  sensitive   = true
}

output "cluster_agent_token" {
  description = "Shared secret accepted only from agents. Re-exported from the shared cluster-facts core. azure-control-plane needs the raw value for its own server-init node-bootstrap call; azure-node-pool never needs it directly (it reads via Key Vault + its own managed identity instead)."
  value       = module.cluster_facts.agent_token
  sensitive   = true
}

output "k8s_version" {
  description = "K8s distro version every unit in this cluster should install. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.k8s_version
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault holding the agent join token. azure-node-pool's own role assignment is scoped under this vault at the individual-secret level. Not consumed by azure-control-plane, so callers that merge() this module's outputs into control-plane's inputs should filter this key out to avoid an undeclared-variable warning."
  value       = azurerm_key_vault.cluster.id
}

output "key_vault_name" {
  description = "Name of the Key Vault holding the agent join token (used to build the vault URI in azure-node-pool's agent_token_fetch_command). Not consumed by azure-control-plane — see key_vault_id's note."
  value       = azurerm_key_vault.cluster.name
}

output "agent_token_secret_name" {
  description = "Name of the Key Vault secret holding the agent join token ('agent-token'). azure-node-pool's managed identity is granted read access scoped to exactly this secret. Not consumed by azure-control-plane — see key_vault_id's note."
  value       = azurerm_key_vault_secret.agent_token.name
}

output "cluster_asg_id" {
  description = "ID of the cluster-wide Application Security Group. Both azure-control-plane's own NICs and azure-node-pool's worker NICs join this by id."
  value       = azurerm_application_security_group.cluster.id
}

output "gitops_platform_enabled" {
  description = "Whether the genesis node should bootstrap kube-platform at all. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.platform_enabled
}

output "gitops_platform_repo_url_override" {
  description = "Consumer override for kube-platform's repo URL, or \"\" to use node-bootstrap's own pinned default. Re-exported from the shared cluster-facts core (see its output description for why \"\" and not null)."
  value       = module.cluster_facts.platform_repo_url_override
}

output "gitops_platform_revision_override" {
  description = "Consumer override for the platform Application's tracked revision, or \"\" to use node-bootstrap's own pinned default. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.platform_revision_override
}

output "gitops_workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, or \"\" for no workloads Application. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.workloads_repo_url
}

output "gitops_workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.workloads_revision
}

output "gitops_workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.workloads_path
}
