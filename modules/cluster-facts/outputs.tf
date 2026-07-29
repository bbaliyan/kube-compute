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
