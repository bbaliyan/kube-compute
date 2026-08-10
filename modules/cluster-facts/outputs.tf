# SPDX-License-Identifier: Apache-2.0
output "server_token" {
  description = "Shared secret used to join a server to the cluster (rke2 config.yaml's token:). Consumed by control-plane's own node-bootstrap calls for both server-init and server-join roles."
  value       = random_password.server_token.result
  sensitive   = true
}

output "agent_token" {
  description = "Separate shared secret accepted only from agents (rke2 config.yaml's agent-token:) — a worker presenting this value can join as an agent but never as a server/etcd member."
  value       = random_password.agent_token.result
  sensitive   = true
}

output "platform_enabled" {
  description = "Whether control-plane's genesis node should bootstrap kube-platform at all. Re-exported verbatim from the input of the same name."
  value       = var.platform_enabled
}

output "platform_repo_url_override" {
  description = "Consumer override for kube-platform's repo URL, or \"\" to use node-bootstrap's own pinned default. \"\" rather than null: OpenTofu drops null-valued root outputs from state entirely, which breaks any Terragrunt dependency block referencing this attribute the moment its value is null (the common case) — \"empty means unset\" is this codebase's established idiom for exactly this reason (see e.g. node-bootstrap's own cluster_fqdn/registration_address handling)."
  value       = var.platform_repo_url_override != null ? var.platform_repo_url_override : ""
}

output "platform_revision_override" {
  description = "Consumer override for the platform Application's tracked revision, or \"\" to use node-bootstrap's own pinned default. See platform_repo_url_override's description for why this is \"\" and not null."
  value       = var.platform_revision_override != null ? var.platform_revision_override : ""
}

output "workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, or \"\" for no workloads Application. See platform_repo_url_override's description for why this is \"\" and not null."
  value       = var.workloads_repo_url != null ? var.workloads_repo_url : ""
}

output "workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Only meaningful when workloads_repo_url is set. Re-exported verbatim."
  value       = var.workloads_revision
}

output "workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Only meaningful when workloads_repo_url is set. Re-exported verbatim."
  value       = var.workloads_path
}
