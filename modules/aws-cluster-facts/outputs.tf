# SPDX-License-Identifier: Apache-2.0
output "server_token" {
  description = "Shared secret used to join a server to the cluster. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.server_token
  sensitive   = true
}

output "agent_token" {
  description = "Shared secret accepted only from agents. Re-exported from the shared cluster-facts core. aws-control-plane needs the raw value for its own server-init node-bootstrap call; aws-node-pool never needs it directly (it fetches via agent_token_ssm_parameter instead)."
  value       = module.cluster_facts.agent_token
  sensitive   = true
}

output "k8s_version" {
  description = "K8s distro version every unit in this cluster should install. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.k8s_version
}

output "cluster_security_group_id" {
  description = "Self-referencing security group id shared by every cluster member. Both aws-control-plane's own instances and aws-node-pool's workers attach to this by id."
  value       = aws_security_group.cluster.id
}

output "agent_token_ssm_parameter" {
  description = "SSM Parameter Store name (SecureString) holding the agent join token. aws-node-pool's workers fetch it at boot via their own instance IAM role — never embedded in user_data."
  value       = aws_ssm_parameter.agent_token.name
}

output "platform_enabled" {
  description = "Whether the genesis node should bootstrap kube-platform at all. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.platform_enabled
}

output "platform_repo_url_override" {
  description = "Consumer override for kube-platform's repo URL, or null to use node-bootstrap's own pinned default. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.platform_repo_url_override
}

output "platform_revision_override" {
  description = "Consumer override for the platform Application's tracked revision, or null to use node-bootstrap's own pinned default. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.platform_revision_override
}

output "workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, or null for no workloads Application. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.workloads_repo_url
}

output "workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.workloads_revision
}

output "workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.workloads_path
}
