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
