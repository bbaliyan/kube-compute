# SPDX-License-Identifier: Apache-2.0
# Output names match aws-control-plane's/aws-node-pool's own variable names
# (cluster_token, gitops_platform_enabled, etc.) rather than the neutral names
# the shared cluster-facts core uses internally — so a caller's Terragrunt
# `inputs` block can pass `dependency.cluster_facts.outputs` straight through
# via merge() instead of remapping every key by hand. The shared core stays
# provider-neutral by design (one implementation serving AWS/Proxmox/Azure
# alike); this wrapper (and its Proxmox/Azure siblings) does the renaming on
# the way out instead.
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
  description = "Shared secret accepted only from agents. Re-exported from the shared cluster-facts core. aws-control-plane needs the raw value for its own server-init node-bootstrap call; aws-node-pool never needs it directly (it fetches via agent_token_ssm_parameter instead)."
  value       = module.cluster_facts.agent_token
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Self-referencing security group id shared by every cluster member. Both aws-control-plane's own instances and aws-node-pool's workers attach to this by id."
  value       = aws_security_group.cluster.id
}

output "agent_token_ssm_parameter" {
  description = "SSM Parameter Store name (SecureString) holding the agent join token. aws-node-pool's workers fetch it at boot via their own instance IAM role — never embedded in user_data. Not consumed by aws-control-plane, so callers that merge() this module's outputs into control-plane's inputs should filter this key out to avoid an undeclared-variable warning."
  value       = aws_ssm_parameter.agent_token.name
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
