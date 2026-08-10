# SPDX-License-Identifier: Apache-2.0
# Output names match aws-control-plane's/aws-node-pool's own variable names
# (cluster_token, agent_token_ssm_parameter, etc.) so a caller's Terragrunt
# `inputs` block can source them directly without remapping every key by hand.
output "cluster_name" {
  description = "Cluster identity, as passed in. Re-exported verbatim so control-plane/node-pool source it from here instead of re-deriving or re-hardcoding it."
  value       = var.cluster_name
}

output "cluster_token" {
  description = "Shared secret used to join a server to the cluster."
  value       = random_password.server_token.result
  sensitive   = true
}

output "cluster_agent_token" {
  description = "Shared secret accepted only from agents. aws-control-plane needs the raw value for its own server-init node-bootstrap call; aws-node-pool never needs it directly (it fetches via agent_token_ssm_parameter instead)."
  value       = random_password.agent_token.result
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
