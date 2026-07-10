# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to cloud-init) ----
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Defaults to the bundled Ubuntu 26.04 LTS template. Supply your own path for other distributions — no compatibility guarantee is made for untested distributions."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Cluster identity. Used in VM names, tags, FQDN, and the kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version (a K3s release string today, e.g. v1.36.1+k3s1). Neutral name. Null uses the platform default (module.component_versions.k8s_version)."
  type        = string
  default     = null
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
  description = "CNI to install: 'flannel' or 'cilium'. Null (default) auto-derives to 'cilium' when control_plane_count > 1 and 'flannel' for control_plane_count = 1. Set explicitly to override."
  type        = string
  default     = null
  validation {
    condition     = var.cni == null || contains(["flannel", "cilium"], var.cni)
    error_message = "cni must be null, 'flannel', or 'cilium'."
  }
}

variable "etcd_snapshots_enabled" {
  description = "Enable K3s' built-in scheduled etcd snapshots (local only — Proxmox has no S3-equivalent wired in this module; use a future NFS/S3-compatible option if needed). Null (default) auto-derives to true when control_plane_count > 1 and false for control_plane_count = 1."
  type        = bool
  default     = null
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule for etcd snapshots. Only meaningful when etcd_snapshots_enabled resolves to true."
  type        = string
  default     = "0 */12 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Number of local etcd snapshots to retain. Only meaningful when etcd_snapshots_enabled resolves to true."
  type        = number
  default     = 5
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

variable "ssh_authorized_keys" {
  description = "SSH public keys injected into the default cloud user via the Proxmox cloud-init drive, for out-of-band VM access. Null = no keys injected."
  type        = list(string)
  default     = null
}

variable "dns_servers" {
  description = "DNS nameserver addresses written into every control-plane VM's cloud-init network-config."
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
  description = "Static IPv4 addresses in CIDR notation (e.g. '192.168.1.10/24'), one per control-plane node, in order. Required when control_plane_count > 1 (join tokens, TLS SANs, and the etcd firewall ipset all need known IPs at plan time — DHCP is only supported for control_plane_count = 1). Null with control_plane_count = 1 falls back to DHCP, matching node-proxmox's existing behavior."
  type        = list(string)
  default     = null

  validation {
    condition     = var.control_plane_count == 1 || (var.control_plane_ip_addresses != null && length(var.control_plane_ip_addresses) == var.control_plane_count)
    error_message = "control_plane_ip_addresses must be set with exactly control_plane_count entries when control_plane_count > 1."
  }
}

variable "vm_gateway" {
  description = "IPv4 default gateway for every control-plane VM (e.g. '192.168.1.1'). Required when control_plane_ip_addresses is set; ignored for DHCP."
  type        = string
  default     = null
}

variable "control_plane_vip_address" {
  description = "kube-vip virtual IP (bare IPv4, no CIDR suffix) on the cluster's L2 subnet, used as the registration_address when control_plane_count > 1. Required in that case — Proxmox has no load balancer primitive, so a floating ARP VIP is the HA registration endpoint."
  type        = string
  default     = null

  validation {
    condition     = var.control_plane_count == 1 || var.control_plane_vip_address != null
    error_message = "control_plane_vip_address is required when control_plane_count > 1."
  }
}

variable "cluster_network_cidr" {
  description = "CIDR of the cluster's L2 subnet (e.g. '192.168.1.0/24'), used as the sole member of the cluster-wide firewall ipset. Proxmox multi-node is a single flat L2 subnet, and bpg/proxmox's ipset resource is owned monolithically by one Terraform state, so exact per-VM membership (AWS's self-referencing security group) can't span the control plane's and each node pool's separate states — this CIDR is the pragmatic Proxmox equivalent of 'this cluster's own members'. Required when control_plane_count > 1 or when any node pool will attach; optional (module still creates the ipset) for a single-node cluster with no pools."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports from outside the cluster — the networks you administer/reach the cluster from. Required — environment-specific."
  type        = list(string)
}

variable "ingress_ports" {
  description = "TCP ports opened from allowed_ingress_cidrs on every control-plane VM: 443/80 Traefik, 6443 K3s API. Never add 22 (SSH)."
  type        = list(number)
  default     = [80, 443, 6443]
}

# DNS: optional naming only. This module creates NO DNS records — Proxmox has no managed DNS.
variable "cluster_domain" {
  description = "Optional DNS suffix (e.g. 'homelab.local'). When set, FQDN = api.<cluster_name>.<cluster_domain> and wildcard = *.<cluster_name>.<cluster_domain>. No DNS record is created — register wildcard_dns_name at cluster_ip/control_plane_vip_address in your local resolver."
  type        = string
  default     = null
}
