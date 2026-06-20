# SPDX-License-Identifier: Apache-2.0

# ---- Standardized outputs (identical names across all provider modules) ----

output "instance_id" {
  description = "Provider-native node ID. For Proxmox: the VM ID as a string."
  value       = tostring(proxmox_virtual_environment_vm.node.vm_id)
}

output "cluster_ip" {
  description = "Node IP. Known at plan time for static addresses; populated from qemu-guest-agent after boot for DHCP. Register your DNS wildcard at this address."
  value       = local.cluster_ip
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given (IP-only)."
  value       = local.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier ('proxmox'). Control-plane scripts dispatch via qm guest exec for this provider."
  value       = "proxmox"
}

output "bootstrap_status_ref" {
  description = "VM ID used to read bootstrap status. Usage: qm guest exec <vmid> -- cat /var/log/kube-node/bootstrap-status"
  value       = tostring(proxmox_virtual_environment_vm.node.vm_id)
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services (e.g. *.bharat.homelab.local), or null when no cluster_domain was given. Add one wildcard A record pointing at cluster_ip in Pi-hole/AdGuard/Technitium/dnsmasq."
  value       = local.wildcard_name
}

# ---- Proxmox-specific extras ----

output "node_arch" {
  description = "CPU architecture as declared by the operator (arm64 or x86_64). Proxmox has no API equivalent of AWS's aws_ec2_instance_type — value comes from the node_arch variable."
  value       = var.node_arch
}

output "vm_id" {
  description = "Proxmox VM ID as a number. Useful for qm commands: qm guest exec <vm_id> ..."
  value       = proxmox_virtual_environment_vm.node.vm_id
}

output "proxmox_node" {
  description = "Proxmox node the VM runs on. Control-plane scripts need this to target the right node for qm commands."
  value       = var.proxmox_node
}
