# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "Cluster identity this pool joins. Must match the control plane's cluster_name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "pool_name" {
  description = "Names this pool's VMs <cluster_name>-<pool_name>-<n> and labels every node kube-compute.io/node-group=<pool_name>, which a nodeSelector can pin pods to. Distinct per pool, or two pools' VMs and snippets collide."
  type        = string
  default     = "worker"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.pool_name))
    error_message = "pool_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
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

variable "pool_id" {
  description = "Proxmox resource pool the worker VMs join. Null (default) puts them in no pool. A token scoped to one pool can only create VMs there."
  type        = string
  default     = null
}

variable "cpu_units" {
  description = "Proxmox CPU weight (cpuunits) of each worker VM: its share of CPU time when the host is busy, relative to other VMs. A lower value yields CPU to other VMs. Null (default) keeps the Proxmox default."
  type        = number
  default     = null

  validation {
    condition     = var.cpu_units == null ? true : var.cpu_units >= 1 && var.cpu_units <= 262144
    error_message = "cpu_units must be between 1 and 262144, the range Proxmox accepts."
  }
}

variable "proxmox_template_vm_id" {
  description = "VM ID of the kube-images Proxmox template to full-clone every worker from. A new value reaches only new or replaced VMs. Existing VMs keep their disks. To roll nodes one at a time, see 'Rolling to a new template' in the README."
  type        = number
  nullable    = false
}

variable "ssh_authorized_keys" {
  description = "SSH public keys injected into the default cloud user via cloud-init."
  type        = list(string)
  default     = null
}

variable "dns_servers" {
  description = "DNS nameserver addresses written into the cloud-init network-config of every VM. They also give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record."
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
  description = "The address workers join through. Null (the default) computes genesis.<cluster_name>.<cluster_domain>, which needs cluster_domain and dns_server_address. Set a literal IP only when DNS is not configured. Do not use cluster_fqdn: a round-robin record can hang joins for 10 minutes or more."
  type        = string
  default     = null
}

variable "cluster_agent_token" {
  description = "Agent join token for this cluster, embedded in this pool's cloud-init. Take it from the cluster_agent_token output of the control plane at the consumer layer. Sensitive."
  type        = string
  sensitive   = true
}

variable "extra_node_labels" {
  description = "Additional node-label: entries for every worker in this pool."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Taints on every worker in this pool, each key=value:Effect. A label only lets pods be pinned here; a taint keeps every pod without a matching toleration off."
  type        = list(string)
  default     = []
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed to reach ingress_ports on this pool's workers from outside the cluster. Set on the pool that runs ingress."
  type        = list(string)
  default     = []
}

variable "ingress_ports" {
  description = "TCP ports opened from allowed_ingress_cidrs on this pool's workers, e.g. [80, 443] for Traefik. Never add 22 (SSH)."
  type        = list(number)
  default     = []
}

variable "manage_wildcard_dns_record" {
  description = "Whether this pool publishes *.<cluster_name> at its workers when DNS is configured. Only one pool of a cluster should, the one running ingress."
  type        = bool
  default     = true
}

# ---- Wildcard DNS registration (optional): publishes *.<cluster_name> via RFC2136 ----
# On a dedicated_control_plane cluster the control plane is tainted, so this
# pool's workers are where ingress actually runs — this pool, not
# proxmox-control-plane, owns the wildcard record in that shape. All
# null/default = no record published, same "DNS is optional, name-only by
# default" rule as every other provider module. Mirrors
# proxmox-control-plane's identical dns_server_address/tsig_* block.
variable "cluster_dns_name" {
  description = "Name to use in DNS in place of cluster_name. See proxmox-cluster's own variable."
  type        = string
  default     = null
  validation {
    condition     = var.cluster_dns_name == null || can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_dns_name))
    error_message = "cluster_dns_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "cluster_domain" {
  description = "DNS suffix matching the control plane's own cluster_domain (e.g. 'cluster.example'). Required to compute the wildcard record's zone; ignored when dns_server_address is null."
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
  description = "Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Ignored when dns_server_address is null. Defaults to 'udp'. See proxmox-control-plane's identical variable."
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

variable "graceful_shutdown" {
  description = "How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}
}

variable "os_auto_updates" {
  description = "Installs OS updates daily with dnf-automatic, without rebooting. See node-bootstrap's own variable."
  type        = bool
  default     = true
}

variable "node_name_template" {
  description = "Name for each worker of the pool: its VM name, hostname and Kubernetes node name. {number} becomes the worker's number as two digits (01, 02, ...) and is required. Null keeps <cluster_name>-<pool_name>-<n>, counting from 0."
  type        = string
  default     = null

  validation {
    condition     = var.node_name_template == null || (can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", replace(coalesce(var.node_name_template, "-"), "{number}", "00"))) && strcontains(coalesce(var.node_name_template, "-"), "{number}"))
    error_message = "node_name_template must give a valid hostname: lowercase letters, digits and hyphens, not starting or ending with a hyphen, at most 63 characters, with {number} as the only placeholder. It must contain {number}, so every worker gets its own name."
  }
}

variable "cloud_init_upload_mode" {
  description = "How the provider copies cloud-init snippets to the Proxmox host over SSH. Null keeps the provider default, 'stream', which uses sudo. 'sftp' needs write access to the snippets directory and no sudo. It does not affect ISO or image downloads."
  type        = string
  default     = null

  validation {
    condition     = var.cloud_init_upload_mode == null ? true : contains(["stream", "sftp"], var.cloud_init_upload_mode)
    error_message = "cloud_init_upload_mode must be null, \"stream\" or \"sftp\"."
  }
}
