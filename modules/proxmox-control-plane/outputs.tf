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
  description = "Genesis control-plane node's IP. For control_plane_count > 1, prefer cluster_fqdn (when dns_registration_enabled) for a name that covers every control-plane node, not just genesis."
  value       = local.cp_ips["0"]
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given. This name is always computed from cluster_domain, whether or not anything actually publishes it to DNS — see dns_registration_enabled before connecting through it. For kubectl/human access only: don't wire this into proxmox-node-pool's registration_address (see that variable's own doc for why worker joins need a single fixed name instead)."
  value       = local.cluster_fqdn
}

output "dns_registration_enabled" {
  description = "Whether this control plane actually published cluster_fqdn to a DNS server via dns-registration (true only when dns_server_address was set). Consumers deciding whether to connect via cluster_fqdn rather than a raw IP for kubectl/human access should check this first — cluster_fqdn is a non-null name whenever cluster_domain is set, regardless of whether anything makes it resolve. Does not apply to worker joins, which self-compute their own single-target registration address (proxmox-node-pool's registration_address variable) rather than reading it from this module."
  value       = local.dns_registration_enabled
}

output "node_provider" {
  description = "Provider identifier ('proxmox'). Control-plane scripts dispatch via qm guest exec for this provider."
  value       = "proxmox"
}

output "node_control_ref" {
  description = "Genesis VM ID, for control-plane verb-scripts that need a single node reference. Renamed from bootstrap_status_ref: no status file exists to reference anymore now that cloud-init (not Ansible) owns bootstrap."
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

output "ansible_ssh_user" {
  description = "SSH user for guest access (os-patch and any other ops tooling connecting to the node directly) — node-bootstrap itself no longer connects to the node at all; this account exists for day-2 tooling only."
  value       = var.ansible_ssh_user
}

output "ansible_ssh_private_key_file" {
  description = "Path to the SSH private key for guest access — same key node-bootstrap itself connects with. Not marked sensitive: a path, not the key material itself."
  value       = var.ansible_ssh_private_key_file
}

output "k8s_version" {
  description = "K8s distro version installed on this control plane's control-plane nodes."
  value       = var.k8s_version
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
