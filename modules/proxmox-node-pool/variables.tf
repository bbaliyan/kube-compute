# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to node-bootstrap) ----
variable "ansible_playbook_path" {
  description = "Absolute path to the Ansible playbook to run. Defaults to the bundled AlmaLinux 10 playbook."
  type        = string
  default     = null
}

variable "ansible_ssh_private_key_file" {
  description = "Path to the SSH private key Ansible uses to reach each worker (the public half must be in ssh_authorized_keys). Matches kube-devenv's kube-shell/kube-status default key."
  type        = string
  default     = "~/.ssh/id_ed25519_kube_cluster"
}

variable "ansible_ssh_user" {
  description = "SSH user Ansible connects as. Matches kube-devenv's kube-shell/kube-status default user for the AlmaLinux 10 image."
  type        = string
  default     = "almalinux"
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
  description = "The address workers join through — opaque to this module. Prefer the control plane's registration_address output (genesis's raw IP), not its cluster_fqdn: a real multi-CP apply found that pointing all workers at a DNS name resolving to every control-plane IP causes join hangs lasting 10-20+ minutes per worker — retries land on different control-plane nodes across a round-robin/multi-address record, racing RKE2's own per-node 'orphaned node-password secret' garbage collection (~10 min window), which deletes a still-in-progress join credential signed by a different node than the one now being asked. Pinning every worker to one fixed control-plane IP avoids the race entirely; only kubectl/human access should use cluster_fqdn (unaffected by this issue). Workers join via config.yaml's server: https://<this>:9345 (RKE2's supervisor/join port, distinct from the 6443 Kubernetes API port)."
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
  description = "TTL in seconds for the published wildcard record. Ignored when dns_server_address is null."
  type        = number
  default     = 300
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
