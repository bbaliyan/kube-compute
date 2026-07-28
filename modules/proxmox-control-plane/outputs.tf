# SPDX-License-Identifier: Apache-2.0

output "cluster_name" {
  description = "Cluster name passed to the module."
  value       = var.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID of the genesis control-plane VM."
  value       = tostring(proxmox_virtual_environment_vm.control_plane.vm_id)
}

output "cluster_ip" {
  description = "Genesis control-plane node's IP. For control_plane_count > 1, prefer registration_address."
  value       = local.cp_ips["0"]
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given. This name is always computed from cluster_domain, whether or not anything actually publishes it to DNS — see dns_registration_enabled before joining through it."
  value       = local.cluster_fqdn
}

output "dns_registration_enabled" {
  description = "Whether this control plane actually published cluster_fqdn to a DNS server via dns-registration (true only when dns_server_address was set). Consumers deciding whether to join/connect via cluster_fqdn rather than registration_address (a raw IP) should check this first — cluster_fqdn is a non-null name whenever cluster_domain is set, regardless of whether anything makes it resolve."
  value       = local.dns_registration_enabled
}

output "node_provider" {
  description = "Provider identifier ('proxmox'). Control-plane scripts dispatch via qm guest exec for this provider."
  value       = "proxmox"
}

output "node_control_ref" {
  description = "Genesis VM ID, for control-plane verb-scripts that need a single node reference. Renamed from bootstrap_status_ref: no status file exists to reference anymore now that Ansible (not cloud-init) owns bootstrap."
  value       = tostring(proxmox_virtual_environment_vm.control_plane.vm_id)
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services, or null when no cluster_domain was given. On an all_in_one cluster this module also publishes it to DNS itself (at cluster_ip) whenever dns_server_address is set — check wildcard_registration_enabled. On a dedicated_control_plane cluster this module never publishes it (the control plane is tainted; proxmox-node-pool publishes it instead, at its own worker IPs) — register it yourself if that pool's DNS registration isn't enabled either."
  value       = local.wildcard_name
}

output "wildcard_registration_enabled" {
  description = "Whether this control plane actually published wildcard_dns_name to DNS itself (true only for an all_in_one cluster with dns_server_address set). Always false for dedicated_control_plane — see wildcard_dns_name."
  value       = local.wildcard_registration_enabled
}

output "node_arch" {
  description = "CPU architecture as declared by the operator."
  value       = var.node_arch
}

output "proxmox_node" {
  description = "Proxmox node every control-plane VM runs on."
  value       = var.proxmox_node
}

output "k8s_version" {
  description = "K8s distro version installed on this control plane's control-plane nodes. Wire proxmox-node-pool's control_plane_k8s_version to this output so the version-skew guard is enforced automatically rather than by convention."
  value       = local.k8s_version
}

# ---- Join flow: consumed by proxmox-node-pool ----
output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API: genesis's raw IP. Proxmox has no load-balancer primitive, so every node (control-plane joiner or worker) dials genesis directly rather than a VIP; cluster_fqdn (when dns_server_address is set) is the DNS-based alternative for clients outside this join flow."
  value       = local.cp_ips["0"]
}

output "cluster_agent_token" {
  description = "The agent join token. Delivered to proxmox-node-pool directly (no managed secret store on Proxmox); embed it in cloud-init only, never log it."
  value       = random_password.agent_token.result
  sensitive   = true
}

output "cluster_ipset_name" {
  description = "Name of the cluster-wide firewall ipset (see module README for its subnet-CIDR scoping rationale). Node pools reference this by name ('+<name>') in their own per-VM firewall rules — they never create or own this ipset."
  value       = local.cluster_ipset_name
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, ip, provider}."
  value = merge(
    {
      "${var.cluster_name}-cp-0" = {
        instance_id = tostring(proxmox_virtual_environment_vm.control_plane.vm_id)
        ip          = local.cp_ips["0"]
        provider    = "proxmox"
      }
    },
    {
      for k, vm in proxmox_virtual_environment_vm.control_plane_additional :
      "${var.cluster_name}-cp-${k}" => {
        instance_id = tostring(vm.vm_id)
        ip          = local.cp_ips[k]
        provider    = "proxmox"
      }
    }
  )
}
