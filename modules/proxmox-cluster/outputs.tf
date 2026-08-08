# SPDX-License-Identifier: Apache-2.0

output "cluster_name" {
  description = "Cluster name passed to the module."
  value       = module.control_plane.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID of the genesis control-plane VM."
  value       = module.control_plane.instance_id
}

output "cluster_ip" {
  description = "Genesis control-plane node's IP. For control_plane_count > 1, prefer cluster_fqdn (when dns_registration_enabled) for a name that covers every control-plane node, not just genesis."
  value       = module.control_plane.cluster_ip
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given."
  value       = module.control_plane.cluster_fqdn
}

output "dns_registration_enabled" {
  description = "Whether the control plane actually published cluster_fqdn to a DNS server."
  value       = module.control_plane.dns_registration_enabled
}

output "node_provider" {
  description = "Provider identifier ('proxmox')."
  value       = module.control_plane.node_provider
}

output "node_control_ref" {
  description = "Genesis VM ID, for control-plane verb-scripts that need a single node reference."
  value       = module.control_plane.node_control_ref
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services, or null when no cluster_domain was given."
  value       = module.control_plane.wildcard_dns_name
}

output "wildcard_registration_enabled" {
  description = "Whether the control plane itself published wildcard_dns_name to DNS."
  value       = module.control_plane.wildcard_registration_enabled
}

output "node_arch" {
  description = "CPU architecture as declared by the operator."
  value       = module.control_plane.node_arch
}

output "proxmox_node" {
  description = "Proxmox node the control-plane VM(s) run on."
  value       = module.control_plane.proxmox_node
}

output "ansible_ssh_user" {
  description = "SSH user for guest access."
  value       = module.control_plane.ansible_ssh_user
}

output "ansible_ssh_private_key_file" {
  description = "Path to the SSH private key for guest access."
  value       = module.control_plane.ansible_ssh_private_key_file
}

output "cluster_token" {
  description = "Shared secret used to join a server to the cluster."
  value       = module.control_plane.cluster_token
  sensitive   = true
}

output "cluster_agent_token" {
  description = "Shared secret accepted only from agents. Also wired internally into every module.node_pools entry — exposed here for consumers that need it directly (e.g. a hand-rolled worker outside node_pools)."
  value       = module.control_plane.cluster_agent_token
  sensitive   = true
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, ip, provider}."
  value       = module.control_plane.control_plane_node_refs
}

output "node_pools" {
  description = "Map of pool name (matching var.node_pools' own keys) -> {node_provider, worker_node_refs, wildcard_dns_registration_enabled}, one entry per configured pool. Empty map when var.node_pools is empty."
  value = {
    for name, pool in module.node_pools : name => {
      node_provider                     = pool.node_provider
      worker_node_refs                  = pool.worker_node_refs
      wildcard_dns_registration_enabled = pool.wildcard_dns_registration_enabled
    }
  }
}

output "orchestrator_playbook_path" {
  description = "Absolute path to the cross-node OS-patch orchestrator playbook (node-os-patch). Run it with -e \"$(tofu output -raw orchestrator_extra_vars_json)\". Resource-less — applying this module creates nothing; OS patching is an operator-triggered action run on whatever schedule the operator chooses, never implied by a plain apply."
  value       = module.os_patch.orchestrator_playbook_path
}

output "orchestrator_extra_vars_json" {
  description = "JSON-encoded extra-vars for orchestrator_playbook_path: this cluster's control-plane and worker node refs (across every node_pools entry), SSH connection facts, and per-role RKE2 service names."
  value       = module.os_patch.orchestrator_extra_vars_json
}
