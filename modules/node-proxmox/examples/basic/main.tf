# SPDX-License-Identifier: Apache-2.0
# Minimal node-proxmox usage. Replace values for your environment.
# For `tofu plan` illustration only (no backend wired).
provider "proxmox" {
  endpoint = "https://pve.homelab.local:8006"
  insecure = true  # set false when Proxmox uses a trusted TLS cert

  # SSH is required by bpg/proxmox for snippet file uploads.
  # Set via PROXMOX_VE_SSH_USERNAME + PROXMOX_VE_SSH_PASSWORD (or _SSH_PRIVATE_KEY),
  # or configure the ssh {} block here.
  ssh {
    agent    = true
    username = "root"
    node {
      name    = "pve"
      address = "192.168.1.1"
    }
  }
}

module "cluster" {
  source = "../.."

  cluster_name = "homelab-1"
  k8s_version  = "v1.36.1+k3s1"
  proxmox_node = "pve"

  vm_cores     = 4
  vm_memory_mb = 8192
  vm_disk_gb   = 50

  # Rocky Linux 10 GenericCloud (RHEL-family, required for cloud-init compatibility).
  # Renamed to .img to satisfy Proxmox's iso extension check.
  os_image_url = "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud.latest.x86_64.qcow2"

  # Static IP is strongly recommended — DHCP makes DNS unreliable and cluster_ip
  # is unavailable at plan time.
  vm_ip_address = "192.168.1.10/24"
  vm_gateway    = "192.168.1.1"

  # Optional: set a domain to populate wildcard_dns_name and cluster_fqdn.
  # No DNS record is created — register wildcard_dns_name at cluster_ip yourself.
  # cluster_domain = "homelab.local"

  # Optional: registry mirror, trusted CA, GitOps.
  # registry_mirror_url      = "https://harbor.homelab.local"
  # gitops_platform_repo_url = "https://github.com/me/kube-platform.git"
}

output "register_this_dns" {
  description = "Add a wildcard A record in Pi-hole/AdGuard/dnsmasq pointing at cluster_ip. Null when no cluster_domain is set."
  value = {
    name = module.cluster.wildcard_dns_name
    ip   = module.cluster.cluster_ip
  }
}

output "control_plane" {
  description = "Use these for out-of-band access: qm guest exec <vm_id> -- cat /var/log/kube-node/bootstrap-status"
  value = {
    proxmox_node = module.cluster.proxmox_node
    vm_id        = module.cluster.vm_id
  }
}
