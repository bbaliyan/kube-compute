# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "Cluster identity this pool joins. Must match the control plane's cluster_name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
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

variable "proxmox_template_vm_id" {
  description = "VM ID of a pre-baked kube-image Proxmox VM template to full-clone every worker from, instead of booting a stock cloud image. The template already carries OS prep, the RKE2 binaries (both the server and agent units — this pool enables only rke2-agent at launch), SELinux policy, kernel modules, and the guest agent. Null (the default) keeps the stock path via os_image_url/os_image_file_id — kube-image is opt-in. Set exactly one of os_image_url, os_image_file_id, or proxmox_template_vm_id. No compatibility validation is performed between this ID and what is actually baked in it."
  type        = number
  default     = null
}

variable "ssh_authorized_keys" {
  description = "SSH public keys injected into the default cloud user via cloud-init."
  type        = list(string)
  default     = null
}

variable "dns_servers" {
  description = "DNS nameserver addresses written into every worker's cloud-init network-config, and passed through to node-bootstrap to give kubelet a search-domain-free resolv-conf — defense in depth against any node-inherited DNS search domain colliding with a wildcard cluster DNS record, on top of node-bootstrap's own prefer_fqdn_over_hostname fix for the specific hostname-derived case (see node-bootstrap's dns_servers variable for the full picture)."
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

variable "registration_address" {
  description = "The address workers join through. Null (the default) self-computes the genesis node's single-target self-registered DNS name (genesis.<cluster_name>.<cluster_domain>) — requires cluster_domain and dns_server_address to both be set. Pass an explicit value only when DNS isn't configured (the operator must then know and pin genesis's actual address themselves, e.g. a literal IP, matching how worker_ip_addresses is already a literal in this same file). Prefer the self-computed DNS name over cluster_fqdn (the round-robin api.* record) — a round-robin record causes 10-20+ minute join hangs that a single-target name does not."
  type        = string
  default     = null
}

variable "cluster_agent_token" {
  description = "The agent join token for this cluster. Embedded directly into this pool's cloud-init (no managed secret store on Proxmox). Sourced from the control plane's own cluster_agent_token output at the consumer's Terragrunt layer — there is no Terraform-level dependency between this module and proxmox-control-plane, only a value handed through. Sensitive."
  type        = string
  sensitive   = true
}

variable "extra_node_labels" {
  description = "Additional node-label: entries for every worker in this pool."
  type        = map(string)
  default     = {}
}

# ---- Wildcard DNS registration (optional): publishes *.<cluster_name> via RFC2136 ----
# On a dedicated_control_plane cluster the control plane is tainted, so this
# pool's workers are where ingress actually runs — this pool, not
# proxmox-control-plane, owns the wildcard record in that shape. All
# null/default = no record published, same "DNS is optional, name-only by
# default" rule as every other provider module. Mirrors
# proxmox-control-plane's identical dns_server_address/tsig_* block.
variable "cluster_domain" {
  description = "DNS suffix matching the control plane's own cluster_domain (e.g. 'homelab.local'). Required to compute the wildcard record's zone; ignored when dns_server_address is null."
  type        = string
  default     = null
}

variable "dns_server_address" {
  description = "Hostname or IPv4 address of an RFC2136-compliant DNS server to publish the wildcard record to. Null (default) skips DNS registration entirely; register the wildcard yourself in that case."
  type        = string
  default     = null
}

variable "dns_server_port" {
  description = "Port the DNS server accepts dynamic updates on. Ignored when dns_server_address is null."
  type        = number
  default     = 53
}

variable "dns_transport" {
  description = "Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Ignored when dns_server_address is null. Defaults to 'udp' — see proxmox-control-plane's identical variable for why (tcp was found to fail against Technitium with a mid-update EOF)."
  type        = string
  default     = "udp"
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.dns_transport)
    error_message = "dns_transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
}

variable "dns_record_ttl" {
  description = "TTL in seconds for the published wildcard record. Ignored when dns_server_address is null. Kept low by default — see proxmox-control-plane's dns_record_ttl for why a low TTL matters here (downstream resolver caching can otherwise stale-block a fresh apply for up to a full TTL)."
  type        = number
  default     = 30
}

variable "tsig_key_name" {
  description = "Name of the TSIG key configured on the DNS server, used to authenticate the dynamic update. Required when dns_server_address is set."
  type        = string
  default     = null
}

variable "tsig_key_algorithm" {
  description = "TSIG key algorithm: 'hmac-md5', 'hmac-sha1', 'hmac-sha256', or 'hmac-sha512'. Must match how the key was created on the DNS server. Ignored when dns_server_address is null."
  type        = string
  default     = "hmac-sha256"
  validation {
    condition     = contains(["hmac-md5", "hmac-sha1", "hmac-sha256", "hmac-sha512"], var.tsig_key_algorithm)
    error_message = "tsig_key_algorithm must be one of: hmac-md5, hmac-sha1, hmac-sha256, hmac-sha512."
  }
}

variable "tsig_key_secret" {
  description = "Base64-encoded TSIG shared secret. Required when dns_server_address is set. Sensitive — supply via a TF_VAR_* environment variable, never committed."
  type        = string
  default     = null
  sensitive   = true
}
