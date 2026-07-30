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

output "k8s_version" {
  description = "K8s distro version every unit in this cluster should install — control-plane and node-pool both consume this instead of computing their own default, so a version-skew guard between them is enforced by construction."
  value       = local.k8s_version
}

output "platform_enabled" {
  description = "Whether control-plane's genesis node should bootstrap kube-platform at all. Re-exported verbatim from the input of the same name."
  value       = var.platform_enabled
}

output "platform_repo_url_override" {
  description = "Consumer override for kube-platform's repo URL, or null to use node-bootstrap's own pinned default. Re-exported verbatim."
  value       = var.platform_repo_url_override
}

output "platform_revision_override" {
  description = "Consumer override for the platform Application's tracked revision, or null to use node-bootstrap's own pinned default. Re-exported verbatim."
  value       = var.platform_revision_override
}

output "workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, or null for no workloads Application. Re-exported verbatim."
  value       = var.workloads_repo_url
}

output "workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Only meaningful when workloads_repo_url is set. Re-exported verbatim."
  value       = var.workloads_revision
}

output "workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Only meaningful when workloads_repo_url is set. Re-exported verbatim."
  value       = var.workloads_path
}
