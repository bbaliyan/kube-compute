# SPDX-License-Identifier: Apache-2.0
output "server_token" {
  description = "Shared secret used to join a server to the cluster. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.server_token
  sensitive   = true
}

output "agent_token" {
  description = "Shared secret accepted only from agents. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.agent_token
  sensitive   = true
}

output "k8s_version" {
  description = "K8s distro version every unit in this cluster should install. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.k8s_version
}

output "cluster_ipset_name" {
  description = "Name of the cluster-wide firewall ipset. proxmox-control-plane still creates the ipset resource itself; this is only the naming convention, so proxmox-node-pool's own firewall rules can reference it by name ('+<name>') without depending on proxmox-control-plane at all."
  value       = local.cluster_ipset_name
}

output "etcd_ipset_name" {
  description = "Name of the etcd-peer firewall ipset. Exposed for symmetry; proxmox-node-pool does not reference it (workers never need etcd-peer access)."
  value       = local.etcd_ipset_name
}
