# SPDX-License-Identifier: Apache-2.0

# ---- Day-2 guest-access credentials (node-bootstrap itself never connects to the
# node — these exist for node-os-patch and any other operator tooling that does) ----
variable "ssh_private_key_file" {
  description = "Path to the SSH private key for guest access (the public half must be in ssh_authorized_keys). Matches kube-devenv's kube-shell/kube-status default key."
  type        = string
  default     = "~/.ssh/id_ed25519_kube_cluster"
}

variable "ssh_user" {
  description = "SSH user for guest access. Matches kube-devenv's kube-shell/kube-status default user for the AlmaLinux 10 image."
  type        = string
  default     = "almalinux"
}

variable "cluster_name" {
  description = "Cluster identity. Used in VM names, tags, FQDN, and the kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to the node OS trust store. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream."
  type        = string
  default     = null
}

variable "gitops_platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application."
  type        = bool
  default     = true
}

variable "gitops_platform_repo_url_override" {
  description = "Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin."
  type        = string
  default     = null
}

variable "gitops_platform_revision_override" {
  description = "Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default."
  type        = string
  default     = null
}

variable "gitops_workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application."
  type        = string
  default     = null
}

variable "gitops_workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops_workloads_repo_url is set."
  type        = string
  default     = "main"
}

variable "gitops_workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Only meaningful when gitops_workloads_repo_url is set."
  type        = string
  default     = "."
}

variable "cluster_type" {
  description = "Cluster topology intent: 'all_in_one' (control-plane nodes stay schedulable) or 'dedicated_control_plane' (control-plane nodes are tainted so user workloads run only on separate node pools)."
  type        = string
  default     = "all_in_one"
  validation {
    condition     = contains(["all_in_one", "dedicated_control_plane"], var.cluster_type)
    error_message = "cluster_type must be 'all_in_one' or 'dedicated_control_plane'."
  }
}

variable "cni" {
  description = "CNI to install: 'default' or 'cilium'. Null (default) resolves to 'cilium' regardless of topology — Canal/flannel's iptables/ipset dataplane ('default') is broken on AlmaLinux 10, this project's only supported OS (its kernel dropped modules flannel and Felix require). 'default' remains an escape hatch for a consumer-supplied playbook targeting a different OS."
  type        = string
  default     = null
  validation {
    condition     = var.cni == null || contains(["default", "cilium"], var.cni)
    error_message = "cni must be null, 'default', or 'cilium'."
  }
}

variable "cert_mode" {
  description = "Certificate issuer mode deployed by kube-platform. 'selfsigned' (default), 'byo', or 'acme'."
  type        = string
  default     = "selfsigned"
  validation {
    condition     = contains(["selfsigned", "byo", "acme"], var.cert_mode)
    error_message = "cert_mode must be 'selfsigned', 'byo', or 'acme'."
  }
}

variable "platform_extra_helm_parameters" {
  description = "Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application."
  type        = map(string)
  default     = {}
}

variable "platform_helm_values_object" {
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional Proxmox VM tags applied to every control-plane VM, and forwarded to cloud-init's platform Application (helm.valuesObject.extraTags)."
  type        = map(string)
  default     = {}
}

# ---- Proxmox-specific inputs ----
variable "proxmox_node" {
  description = "Proxmox node name every control-plane VM is placed on (the hostname shown in the Proxmox UI under Datacenter). Cross-host spread for HA is a future enhancement — all control-plane VMs land on this one Proxmox node today."
  type        = string
}

variable "disk_datastore_id" {
  description = "Proxmox storage ID for VM disks and cloud-init drives. Must support 'images' content type."
  type        = string
  default     = "local-lvm"
}

variable "iso_datastore_id" {
  description = "Proxmox storage ID for the OS image download and cloud-init snippet files. Must support 'iso', 'snippets', and 'import' content types."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox Linux bridge every control-plane VM's NIC attaches to. The module never creates bridges — pass an existing one."
  type        = string
  default     = "vmbr0"
}

variable "vm_cores" {
  description = "Number of vCPU cores per control-plane VM."
  type        = number
}

variable "vm_memory_mb" {
  description = "RAM per control-plane VM in MiB."
  type        = number
}

variable "vm_disk_gb" {
  description = "Root disk size in GiB per control-plane VM."
  type        = number
}

variable "vm_cpu_type" {
  description = "QEMU CPU model. 'x86-64-v2-AES' (default) enables live migration between different CPU generations."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "node_arch" {
  description = "CPU architecture of the control-plane VMs ('x86_64' or 'arm64'). Declared explicitly — Proxmox has no API equivalent of AWS's instance-type architecture lookup."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.node_arch)
    error_message = "node_arch must be 'x86_64' or 'arm64'."
  }
}

variable "os_image_url" {
  description = "URL of the OS cloud image to download to Proxmox storage. Must match the cloud_init_template OS family. Set exactly one of os_image_url or os_image_file_id."
  type        = string
  default     = null
}

variable "os_image_file_name" {
  description = "Override for the filename stored on Proxmox when using os_image_url. Null = basename of os_image_url."
  type        = string
  default     = null
}

variable "os_image_file_id" {
  description = "ID of an image already present on Proxmox storage, to share one downloaded image across many clusters. Set exactly one of os_image_url or os_image_file_id."
  type        = string
  default     = null
}

variable "proxmox_template_vm_id" {
  description = "VM ID of a pre-baked kube-image Proxmox VM template to full-clone every control-plane node from, instead of booting a stock cloud image. The template carries OS prep, RKE2 binaries (both server and agent units — role chosen at launch), SELinux policy, kernel modules, and the guest agent, so a node reaches Ready much faster than the stock-image path. Null (the default) keeps the stock path via os_image_url/os_image_file_id — kube-image is opt-in. Set exactly one of os_image_url, os_image_file_id, or proxmox_template_vm_id. No compatibility validation is performed against what's actually baked in the template — its self-describing name (kube-image-<k8s_version>-<cilium_version>-<argocd_version>-<build-date>) is documentation only."
  type        = number
  default     = null
}

variable "ssh_authorized_keys" {
  description = "SSH public keys injected into the default cloud user via the Proxmox cloud-init drive, for out-of-band VM access. Null = no keys injected."
  type        = list(string)
  default     = null
}

variable "dns_servers" {
  description = "DNS nameserver addresses written into every control-plane VM's cloud-init network-config, and passed through to node-bootstrap to give kubelet a search-domain-free resolv-conf (see node-bootstrap's dns_servers variable: kubelet's default DNS policy otherwise propagates this node's hostname-derived search domain into every pod, colliding with the wildcard cluster DNS record for that zone)."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "control_plane_count" {
  description = "Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain."
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 3, 5], var.control_plane_count)
    error_message = "control_plane_count must be 1, 3, or 5."
  }
}

variable "control_plane_ip_addresses" {
  description = "Static IPv4 addresses in CIDR notation (e.g. '192.168.1.10/24'), one per control-plane node, in order. Optional at any control_plane_count: when null, every control-plane node gets its IP via DHCP, resolved post-apply through the Proxmox guest agent (used for join tokens, TLS SANs, the etcd firewall ipset, and the dns-registration record). Static IPs remain the practical default for HA — genesis must be reachable before joiners' node-bootstrap runs, and DHCP-assigned IPs are only known after each VM boots."
  type        = list(string)
  default     = null

  validation {
    condition     = var.control_plane_ip_addresses == null || length(var.control_plane_ip_addresses) == var.control_plane_count
    error_message = "When set, control_plane_ip_addresses must have exactly control_plane_count entries."
  }
}

variable "vm_gateway" {
  description = "IPv4 default gateway for every control-plane VM (e.g. '192.168.1.1'). Required when control_plane_ip_addresses is set; ignored for DHCP."
  type        = string
  default     = null
}

variable "cluster_network_cidr" {
  description = "CIDR of the cluster's L2 subnet (e.g. '192.168.1.0/24'), used as the sole member of the cluster-wide firewall ipset. Proxmox multi-node is a single flat L2 subnet, and bpg/proxmox's ipset resource is owned monolithically by one Terraform state, so exact per-VM membership (AWS's self-referencing security group) can't span the control plane's and each node pool's separate states — this CIDR is the pragmatic Proxmox equivalent of 'this cluster's own members'. Required when control_plane_count > 1 or any node pool will attach; optional for a single-node cluster with no pools."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports from outside the cluster — the networks you administer/reach the cluster from. Required — environment-specific."
  type        = list(string)
}

variable "ingress_ports" {
  description = "TCP ports opened from allowed_ingress_cidrs on every control-plane VM: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH)."
  type        = list(number)
  default     = [80, 443, 6443]
}

# DNS: cluster_domain is name-only; this module creates NO DNS records on its own.
# Real record publication (optional) is the separate dns_server_address/tsig_* block below.
variable "cluster_domain" {
  description = "DNS suffix (e.g. 'homelab.local'). When set, FQDN = api.<cluster_name>.<cluster_domain> and wildcard = *.<cluster_name>.<cluster_domain>. Required when control_plane_count > 1: Proxmox has no load-balancer/VIP primitive, so cluster_fqdn is the only address that names every control-plane node."
  type        = string
  default     = null

  validation {
    condition     = var.control_plane_count == 1 || var.cluster_domain != null
    error_message = "cluster_domain is required when control_plane_count > 1."
  }
}

# ---- DNS registration (optional): publishes cluster_fqdn via RFC2136 dynamic update ----
# All null/default = no record is published, matching every other provider module's
# "DNS is optional, name-only by default" rule. Set dns_server_address to enable.
variable "dns_server_address" {
  description = "Hostname or IPv4 address of an RFC2136-compliant DNS server to publish cluster_fqdn to (any server that speaks RFC2136 — not tied to a specific product). Null (default) skips DNS registration entirely; register wildcard_dns_name/cluster_fqdn yourself in that case."
  type        = string
  default     = null
}

variable "dns_server_port" {
  description = "Port the DNS server accepts dynamic updates on. Ignored when dns_server_address is null."
  type        = number
  default     = 53
}

variable "dns_transport" {
  description = "Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Ignored when dns_server_address is null. Defaults to 'udp': a real apply against Technitium found 'tcp' fails with 'Error updating DNS record: EOF' (connection drops mid-update); 'udp' is the transport actually proven end-to-end. A handful of IPv4 addresses in one A record set fits comfortably under UDP's message-size limit, so there's no capacity reason to prefer TCP."
  type        = string
  default     = "udp"
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.dns_transport)
    error_message = "dns_transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
}

variable "dns_record_ttl" {
  description = "TTL in seconds for the published cluster_fqdn record, and for the genesis node's own self-registered record. Ignored when dns_server_address is null. Kept low by default — see proxmox-control-plane's dns_record_ttl for why a low TTL matters here (downstream resolver caching can otherwise stale-block a fresh apply's join for up to a full TTL)."
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

# ---- Worker pools (optional, merged into this same directory/state) ----
variable "node_pools" {
  description = "Static worker pools joining this cluster, keyed by pool name (e.g. \"pool-a\"). Each pool is created via proxmox-node-pool, wired to this cluster's cluster_name and cluster_agent_token automatically — do not set either field inside a pool object, they are ignored. Empty map (the default) creates no worker pools. Field names, types, and defaults mirror proxmox-node-pool's own variables.tf exactly (minus cluster_name/cluster_agent_token, which this module supplies)."
  type = map(object({
    trusted_ca_pem         = optional(string)
    registry_mirror_url    = optional(string)
    proxmox_node           = string
    disk_datastore_id      = optional(string, "local-lvm")
    iso_datastore_id       = optional(string, "local")
    network_bridge         = optional(string, "vmbr0")
    vm_cores               = number
    vm_memory_mb           = number
    vm_disk_gb             = number
    vm_cpu_type            = optional(string, "x86-64-v2-AES")
    os_image_url           = optional(string)
    os_image_file_name     = optional(string)
    os_image_file_id       = optional(string)
    proxmox_template_vm_id = optional(number)
    ssh_authorized_keys    = optional(list(string))
    dns_servers            = optional(list(string), ["1.1.1.1", "8.8.8.8"])
    worker_ip_addresses    = optional(list(string))
    vm_gateway             = optional(string)
    desired_count          = optional(number, 2)
    registration_address   = optional(string)
    extra_node_labels      = optional(map(string), {})
    cluster_domain         = optional(string)
    dns_server_address     = optional(string)
    dns_server_port        = optional(number, 53)
    dns_transport          = optional(string, "udp")
    dns_record_ttl         = optional(number, 30)
    tsig_key_name          = optional(string)
    tsig_key_algorithm     = optional(string, "hmac-sha256")
    tsig_key_secret        = optional(string)
  }))
  default = {}
}

# ---- Cluster autoscaler (optional, passed through to proxmox-control-plane/node-bootstrap) ----
variable "cluster_autoscaler_enabled" {
  description = "Whether to genesis-apply CAPI/CAPMOX's MachineDeployment + cluster-autoscaler for this cluster. false (the default) means zero autoscaler-related resources exist — no CAPI install, no MachineDeployment, nothing for cluster-autoscaler to manage."
  type        = bool
  default     = false
}

variable "cluster_autoscaler_worker_min_size" {
  description = "Minimum worker count cluster-autoscaler maintains. Only meaningful when cluster_autoscaler_enabled is true."
  type        = number
  default     = 0
}

variable "cluster_autoscaler_worker_max_size" {
  description = "Maximum worker count cluster-autoscaler will scale to. Only meaningful when cluster_autoscaler_enabled is true."
  type        = number
  default     = 0

  validation {
    condition     = !var.cluster_autoscaler_enabled || var.cluster_autoscaler_worker_max_size > 0
    error_message = "cluster_autoscaler_worker_max_size must be > 0 when cluster_autoscaler_enabled is true — leaving it at the 0 default renders a valid but useless MachineDeployment that can never scale up."
  }
}

variable "cluster_autoscaler_worker_template" {
  description = "VM shape for CAPI-provisioned autoscaled workers — same fields proxmox-node-pool's own node_pools objects carry, mapped to ProxmoxMachineTemplate fields per the research spike's field-mapping table. Null (default) is valid only when cluster_autoscaler_enabled is false."
  type = object({
    vm_cores               = number
    vm_memory_mb           = number
    vm_disk_gb             = number
    proxmox_template_vm_id = number
    network_bridge         = string
    disk_datastore_id      = string
    proxmox_node           = string
  })
  default = null

  validation {
    condition     = !var.cluster_autoscaler_enabled || var.cluster_autoscaler_worker_template != null
    error_message = "cluster_autoscaler_worker_template is required when cluster_autoscaler_enabled is true."
  }
}
