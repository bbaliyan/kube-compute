# SPDX-License-Identifier: Apache-2.0
# Output names match proxmox-control-plane's/proxmox-node-pool's own variable
# names (cluster_token, gitops_platform_enabled, etc.) rather than the
# neutral names the shared cluster-facts core uses internally — so a
# caller's Terragrunt `inputs` block can pass `dependency.cluster_facts.outputs`
# straight through via merge() instead of remapping every key by hand. Every
# output here is consumed by proxmox-control-plane, so that merge is total —
# no unused-key warnings, unlike the AWS/Azure siblings' node-pool-only extras.
output "cluster_name" {
  description = "Cluster identity, as passed in. The single source of truth for this cluster's name — control-plane and node-pool units source it from here instead of each re-deriving or re-hardcoding it."
  value       = var.cluster_name
}

output "cluster_token" {
  description = "Shared secret used to join a server to the cluster. Re-exported from the shared cluster-facts core."
  value       = module.cluster_facts.server_token
  sensitive   = true
}

output "cluster_agent_token" {
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
