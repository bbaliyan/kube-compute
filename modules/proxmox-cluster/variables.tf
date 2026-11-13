# SPDX-License-Identifier: Apache-2.0

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

variable "extra_server_manifests" {
  description = "RKE2 auto-deploy manifest files (filename => YAML), passed through proxmox-control-plane to node-bootstrap, which writes them to /var/lib/rancher/rke2/server/manifests/ on the genesis node only. Content is not interpreted. Empty (the default) adds none."
  type        = map(string)
  default     = {}
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

variable "workloads_extra_helm_parameters" {
  description = "Helm parameters forwarded verbatim to the workloads Application. See node-bootstrap for full description."
  type        = map(string)
  default     = {}
}

variable "workloads_helm_values_object" {
  description = "Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations."
  type        = any
  default     = null
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

variable "pool_id" {
  description = "Proxmox resource pool the control-plane VMs and every node_pools worker join, unless a node_pools entry sets its own pool_id. Null (default) puts them in no pool. A token scoped to one pool can only create VMs there."
  type        = string
  default     = null
}

variable "cpu_units" {
  description = "Proxmox CPU weight (cpuunits) of each control-plane VM and every node_pools worker, unless a node_pools entry sets its own cpu_units. A lower value yields CPU to other VMs. Null (default) keeps the Proxmox default."
  type        = number
  default     = null

  validation {
    condition     = var.cpu_units == null ? true : var.cpu_units >= 1 && var.cpu_units <= 262144
    error_message = "cpu_units must be between 1 and 262144, the range Proxmox accepts."
  }
}

variable "proxmox_template_vm_id" {
  description = "VM ID of the kube-images Proxmox template to full-clone every control-plane node from. A new value reaches only new or replaced VMs. To roll nodes one at a time, see 'Rolling to a new template' in the proxmox-control-plane and proxmox-node-pool READMEs."
  type        = number
  nullable    = false
}

variable "ssh_authorized_keys" {
  description = "SSH public keys injected into the default cloud user via the Proxmox cloud-init drive, for out-of-band VM access. Null = no keys injected."
  type        = list(string)
  default     = null
}

variable "dns_servers" {
  description = "DNS nameserver addresses written into the cloud-init network-config of every VM. They also give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record."
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
  description = "Static IPv4 addresses in CIDR form (e.g. '192.168.1.10/24'), one per control-plane node, in order. Null (the default) uses DHCP. Static addresses are advised for HA, because genesis must be reachable before joiners boot."
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
  description = "CIDR of the cluster's L2 subnet (e.g. '192.168.1.0/24'). It is the only member of the cluster firewall ipset. Required when control_plane_count > 1 or when any node pool attaches."
  type        = string
  default     = null

  # Every VM's firewall admits cluster traffic only from this CIDR; without it
  # the ipset falls back to the genesis node alone and joining nodes can't reach it.
  validation {
    condition     = var.cluster_network_cidr != null || (var.control_plane_count == 1 && length(var.node_pools) == 0)
    error_message = "cluster_network_cidr is required when control_plane_count > 1 or any node pool is set: it is the firewall ipset every node admits cluster traffic from."
  }
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
variable "cluster_dns_name" {
  description = "Name used in DNS in place of cluster_name, so the FQDN is api.<cluster_dns_name>.<cluster_domain>. Null (the default) uses cluster_name."
  type        = string
  default     = null
  validation {
    condition     = var.cluster_dns_name == null || can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_dns_name))
    error_message = "cluster_dns_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "cluster_domain" {
  description = "DNS suffix (e.g. 'cluster.example'). When set, the FQDN is api.<cluster_name>.<cluster_domain> and the wildcard is *.<cluster_name>.<cluster_domain>; cluster_dns_name replaces cluster_name if set. Required when control_plane_count > 1."
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
  description = "Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Ignored when dns_server_address is null. Defaults to 'udp'. Some DNS servers drop a TCP update mid-way. A few IPv4 addresses in one A record set fit well under the UDP message-size limit."
  type        = string
  default     = "udp"
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.dns_transport)
    error_message = "dns_transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
}

variable "dns_record_ttl" {
  description = "TTL in seconds for the published cluster_fqdn record and the genesis node's self-registered record. Ignored when dns_server_address is null. Keep it low; see proxmox-boot-steps' dns_self_register_ttl."
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
  description = "Static worker pools joining this cluster, keyed by pool name (e.g. 'platform'), each created through proxmox-node-pool with the cluster's identity and join token. Workers are named <cluster_name>-<pool>-<n>. A null field takes the cluster's value. Empty (the default) creates none."
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
    pool_id                = optional(string)
    cpu_units              = optional(number)
    proxmox_template_vm_id = optional(number)
    ssh_authorized_keys    = optional(list(string))
    dns_servers            = optional(list(string))
    worker_ip_addresses    = optional(list(string))
    vm_gateway             = optional(string)
    desired_count          = optional(number, 2)
    registration_address   = optional(string)
    extra_node_labels      = optional(map(string), {})
    node_taints            = optional(list(string), [])
    cluster_domain         = optional(string)
    dns_server_address     = optional(string)
    dns_server_port        = optional(number)
    dns_transport          = optional(string)
    dns_record_ttl         = optional(number)
    tsig_key_name          = optional(string)
    tsig_key_algorithm     = optional(string)
    tsig_key_secret        = optional(string)
    node_name_template     = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for pool in values(var.node_pools) : pool.cpu_units == null ? true : pool.cpu_units >= 1 && pool.cpu_units <= 262144])
    error_message = "A node_pools cpu_units must be between 1 and 262144, the range Proxmox accepts."
  }
  validation {
    condition     = length(compact([for pool in values(var.node_pools) : pool.node_name_template])) == length(distinct(compact([for pool in values(var.node_pools) : pool.node_name_template])))
    error_message = "Two node_pools have the same node_name_template, so their workers would share names."
  }
}

variable "platform_node_group" {
  description = "node_pools key of the pool running the platform stack, ingress included. Its node-group label pins the platform pods, it alone opens ingress_ports, and the wildcard DNS record points at its workers. Null keeps all of that on the control plane, or on every pool of a dedicated_control_plane cluster."
  type        = string
  default     = null

  validation {
    condition     = var.platform_node_group == null ? true : contains(keys(var.node_pools), var.platform_node_group)
    error_message = "platform_node_group must name a node_pools entry."
  }
}

variable "graceful_shutdown" {
  description = "How long kubelet delays an OS shutdown to evict pods. critical_seconds is the part reserved for critical pods and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables it. Keep the total well under 2 minutes."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}
}

variable "os_auto_updates" {
  description = "Install OS updates with dnf-automatic on every node, daily and 15 minutes after each boot, without rebooting. RKE2 packages are excluded, because system-upgrade-controller upgrades them. needs-restarting (yum-utils) reports a due reboot. False leaves packages as baked."
  type        = bool
  default     = true
}

variable "control_plane_node_name_template" {
  description = "Name for each control-plane node: its VM name, hostname and Kubernetes node name. {number} becomes the node's number as two digits (01, 02, ...) and is required. Null keeps <cluster_name>-cp-<n>, counting from 0. Each node_pools entry has its own node_name_template."
  type        = string
  default     = null
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
