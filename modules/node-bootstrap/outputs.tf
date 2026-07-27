# SPDX-License-Identifier: Apache-2.0
output "bootstrap_id" {
  description = "operator_connect: the triggering null_resource's id. Depend on this (not just the module call) when another resource must wait for this node's Ansible run to complete, e.g. a load-balancer target-group attachment that should only register a node once it has actually joined. Null in on_node mode, where the caller owns the az vm run-command resource and depends on that instead."
  value       = one(null_resource.ansible_bootstrap[*].id)
}

output "bootstrap_log_path" {
  description = "operator_connect: local path (on whatever machine runs terragrunt apply) where this node's Ansible run output is mirrored, live, via tee — tail -f it for real-time progress since Terraform suppresses the provisioner's own console output (the resource config touches sensitive tokens). Null in on_node mode, where full output streams to the run-command output blob the caller configures."
  value       = local.is_operator_connect ? "/tmp/kube-compute-bootstrap-${var.node_name}.log" : null
}

output "on_node_bundle" {
  description = "on_node mode only (null otherwise): the fully-rendered, self-contained bootstrap runner script — playbook + role zipped and base64'd inside it, no secrets. The caller (an Azure module) delivers this verbatim as the az vm run-command source.script. Ansible runs on the node via -c local."
  value       = local.on_node_bundle
}

output "on_node_secret_env" {
  description = "on_node mode: the secret environment variables (CLUSTER_TOKEN, CLUSTER_AGENT_TOKEN, AGENT_TOKEN_FETCH_COMMAND, TRUSTED_CA_PEM) the caller must pass to az vm run-command as protected parameters — on Linux, named parameters arrive as environment variables, which is exactly how the runner reads them. Same secret set operator_connect delivers via the local-exec environment. Sensitive. Empty for any secret the caller didn't supply."
  value       = local.secret_env
  sensitive   = true
}
