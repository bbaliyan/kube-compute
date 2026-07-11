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
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given."
  value       = local.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier ('proxmox'). Control-plane scripts dispatch via qm guest exec for this provider."
  value       = "proxmox"
}

output "bootstrap_status_ref" {
  description = "Genesis VM ID used to read bootstrap status: qm guest exec <vmid> -- cat /var/log/kube-compute/bootstrap-status."
  value       = tostring(proxmox_virtual_environment_vm.control_plane.vm_id)
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services, or null when no cluster_domain was given. Register it yourself at cluster_ip (single-node) or control_plane_vip_address (HA)."
  value       = local.wildcard_name
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
  description = "Address workers/joining servers use to reach the cluster API: the genesis node's IP for control_plane_count = 1, the kube-vip VIP otherwise."
  value       = local.registration_address != null ? local.registration_address : local.cp_ips["0"]
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

output "rendered_cloud_init" {
  description = "Plaintext rendered cloud-config for the genesis node, passed through from cloud-init. Sensitive — for tests/debugging only."
  value       = module.bootstrap.cloud_init
  sensitive   = true
}

output "rendered_cloud_init_additional" {
  description = "Map of rendered cloud-config for additional control-plane nodes, keyed by index. Sensitive."
  value       = { for k, m in module.bootstrap_additional : k => m.cloud_init }
  sensitive   = true
}
