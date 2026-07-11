# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to cloud-init) ----
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Defaults to the bundled Ubuntu 26.04 LTS template."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Cluster identity this pool joins. Must match the control plane's cluster_name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version this pool's workers install. Must not be newer than control_plane_k8s_version. Null uses the platform default (module.component_versions.k8s_version)."
  type        = string
  default     = null
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to the worker's OS trust store. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror. Null = pull from upstream."
  type        = string
  default     = null
}

# ---- Proxmox-specific inputs (mirrors proxmox-control-plane) ----
variable "proxmox_node" {
  description = "Proxmox node name every worker VM in this pool is placed on."
  type        = string
}

variable "disk_datastore_id" {
  description = "Proxmox storage ID for worker VM disks and cloud-init drives."
  type        = string
  default     = "local-lvm"
}

variable "iso_datastore_id" {
  description = "Proxmox storage ID for the OS image download and cloud-init snippet files."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox Linux bridge every worker VM's NIC attaches to."
  type        = string
  default     = "vmbr0"
}

variable "vm_cores" {
  description = "Number of vCPU cores per worker VM."
  type        = number
}

variable "vm_memory_mb" {
  description = "RAM per worker VM in MiB."
  type        = number
}

variable "vm_disk_gb" {
  description = "Root disk size in GiB per worker VM."
  type        = number
}

variable "vm_cpu_type" {
  description = "QEMU CPU model."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "os_image_url" {
  description = "URL of the OS cloud image to download. Set exactly one of os_image_url or os_image_file_id."
  type        = string
  default     = null
}

variable "os_image_file_name" {
  description = "Override for the filename stored on Proxmox when using os_image_url."
  type        = string
  default     = null
}

variable "os_image_file_id" {
  description = "ID of an image already present on Proxmox storage."
  type        = string
  default     = null
}

variable "ssh_authorized_keys" {
  description = "SSH public keys injected into the default cloud user via cloud-init."
  type        = list(string)
  default     = null
}

variable "dns_servers" {
  description = "DNS nameserver addresses written into every worker's cloud-init network-config."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "worker_ip_addresses" {
  description = "Static IPv4 addresses in CIDR notation, one per worker (length must equal desired_count). Null = DHCP for every worker."
  type        = list(string)
  default     = null

  validation {
    condition     = var.worker_ip_addresses == null || length(var.worker_ip_addresses) == var.desired_count
    error_message = "worker_ip_addresses, if set, must have exactly desired_count entries."
  }
}

variable "vm_gateway" {
  description = "IPv4 default gateway for every worker VM. Required when worker_ip_addresses is set."
  type        = string
  default     = null
}

variable "desired_count" {
  description = "Fixed pool size — every worker VM this pool creates."
  type        = number
  default     = 2
  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "control_plane_k8s_version" {
  description = "The control plane's k8s_version. This pool's k8s_version is rejected if it is newer."
  type        = string
}

variable "registration_address" {
  description = "The control plane's registration_address output (kube-vip VIP for HA, or the sole node's IP for single-node). Workers join via --server https://<this>:6443."
  type        = string
}

variable "cluster_agent_token" {
  description = "The control plane's cluster_agent_token output. Embedded directly into this pool's cloud-init (no managed secret store on Proxmox). Sensitive."
  type        = string
  sensitive   = true
}

variable "cluster_ipset_name" {
  description = "The control plane's cluster_ipset_name output. Referenced by name ('+<name>') in this pool's own per-VM firewall rules — the pool never creates or owns the ipset itself."
  type        = string
}

variable "extra_node_labels" {
  description = "Additional --node-label flags for every worker in this pool."
  type        = map(string)
  default     = {}
}
