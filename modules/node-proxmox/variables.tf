# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (identical across all provider modules) ----

variable "cluster_name" {
  description = "Cluster identity. Used in VM name, tags, FQDN, and kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version string (e.g. v1.36.1+k3s1). Neutral name."
  type        = string
  default     = "v1.36.1+k3s1"
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to the node OS trust store via update-ca-trust. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror URL (Nexus/Harbor/Artifactory/any). Null = pull from upstream registries."
  type        = string
  default     = null
}

variable "gitops_platform_repo_url" {
  description = "Optional Argo CD platform Application source repo. Null = skip Argo CD wiring."
  type        = string
  default     = null
}

variable "gitops_platform_revision" {
  description = "Branch/tag/SHA the platform Application tracks."
  type        = string
  default     = "main"
}

variable "gitops_workloads_repo_url" {
  description = "Optional user workloads Application source repo. Null = no workloads Application."
  type        = string
  default     = null
}

variable "gitops_workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks."
  type        = string
  default     = "main"
}

variable "gitops_workloads_path" {
  description = "Path within the workloads repo the ApplicationSet scans."
  type        = string
  default     = "apps"
}

variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Defaults to the bundled Ubuntu 26.04 LTS template. Supply your own path for other distributions — no compatibility guarantee is made for untested distributions."
  type        = string
  default     = null
}

# ---- Proxmox-specific inputs ----

variable "proxmox_node" {
  description = "Proxmox node name to place the VM on (the hostname shown in the Proxmox UI under Datacenter)."
  type        = string
}

variable "disk_datastore_id" {
  description = "Proxmox storage ID for the VM disk and cloud-init drive. Must support 'images' content type (e.g. 'local-lvm' for LVM-thin)."
  type        = string
  default     = "local-lvm"
}

variable "iso_datastore_id" {
  description = "Proxmox storage ID for the OS image download and cloud-init snippet files. Must support 'iso', 'snippets', and 'import' content types."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox Linux bridge the VM NIC attaches to. The module never creates bridges — pass an existing one."
  type        = string
  default     = "vmbr0"
}

variable "vm_id" {
  description = "Proxmox VM ID (100–999999). Null = auto-assign the next available ID."
  type        = number
  default     = null
}

variable "vm_cores" {
  description = "Number of vCPU cores allocated to the VM."
  type        = number
}

variable "vm_memory_mb" {
  description = "RAM allocated to the VM in MiB."
  type        = number
}

variable "vm_disk_gb" {
  description = "Root disk size in GiB. The cloud image is imported and expanded to this size on first boot."
  type        = number
}

variable "vm_cpu_type" {
  description = "QEMU CPU model. 'x86-64-v2-AES' (default) enables live migration between different CPU generations. Use 'host' for maximum performance on a single-node homelab."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "vm_numa" {
  description = "Enable NUMA topology. Recommended when vm_cpu_type is 'host' and the physical host has NUMA nodes."
  type        = bool
  default     = false
}

variable "vm_ip_address" {
  description = "Static IPv4 address in CIDR notation (e.g. '192.168.1.10/24'). Null = DHCP. Static IP is strongly recommended: DHCP makes the cluster_ip output unavailable at plan time and makes DNS unreliable across VM restarts."
  type        = string
  default     = null
}

variable "vm_gateway" {
  description = "IPv4 default gateway (e.g. '192.168.1.1'). Required when vm_ip_address is set; ignored for DHCP."
  type        = string
  default     = null
}

variable "os_image_url" {
  description = "URL of the OS cloud image to download to Proxmox (e.g. Ubuntu 26.04 LTS GenericCloud qcow2). Must match the cloud_init_template OS family. Set exactly one of os_image_url or os_image_file_id."
  type        = string
  default     = null
}

variable "os_image_file_name" {
  description = "Override for the filename stored on Proxmox when using os_image_url. Required when the URL path does not end in a Proxmox-accepted extension (.qcow2, .iso). Ubuntu cloud images use .img but are QCOW2 format — pass 'ubuntu-26.04-server-cloudimg-amd64.qcow2' here. Null = use the basename of os_image_url."
  type        = string
  default     = null
}

variable "os_image_file_id" {
  description = "ID of an image already present on Proxmox storage (e.g. 'local:iso/ubuntu-26.04.img'). Use this to share one downloaded image across many clusters instead of downloading per-cluster. Set exactly one of os_image_url or os_image_file_id."
  type        = string
  default     = null
}

variable "ssh_authorized_keys" {
  description = "SSH public keys to inject into the default cloud user via the Proxmox cloud-init drive. Used for direct VM access without requiring an open SSH port in the node firewall — pair with a jump host or VPN. Null = no keys injected."
  type        = list(string)
  default     = null
}

variable "node_arch" {
  description = "CPU architecture of the VM ('x86_64' or 'arm64'). Declared explicitly — Proxmox has no API equivalent of AWS's aws_ec2_instance_type data source. The operator knows their hardware."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.node_arch)
    error_message = "node_arch must be 'x86_64' or 'arm64'."
  }
}

# DNS: optional naming only. This module creates NO DNS records.
# Proxmox has no managed DNS. Register wildcard_dns_name at cluster_ip yourself
# (Pi-hole / AdGuard / Technitium / dnsmasq / RFC2136 / any DNS provider).
variable "cluster_domain" {
  description = "Optional DNS suffix (e.g. 'homelab.local'). When set, FQDN = api.<cluster_name>.<cluster_domain> and wildcard = *.<cluster_name>.<cluster_domain>. No DNS record is created — register wildcard_dns_name at cluster_ip in your local resolver."
  type        = string
  default     = null
}
