# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to cloud-init) ----
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Defaults to the bundled AlmaLinux 9 template. Supply your own path for other distributions — no compatibility guarantee is made for untested distributions."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Cluster identity. Used in VM/resource names, tags, FQDN, and the kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version (an RKE2 release string today, e.g. v1.36.1+rke2r1). Neutral name. Null uses the platform default (module.component_versions.k8s_version)."
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
  description = "CNI to install: 'default' or 'cilium'. Null (default) auto-derives to 'cilium' when control_plane_count > 1 and 'default' for control_plane_count = 1. Set explicitly to override."
  type        = string
  default     = null
  validation {
    condition     = var.cni == null || contains(["default", "cilium"], var.cni)
    error_message = "cni must be null, 'default', or 'cilium'."
  }
}

variable "etcd_snapshots_enabled" {
  description = "Enable RKE2's built-in scheduled etcd snapshots (local only — no object-store upload is wired in this module). Null (default) auto-derives to true when control_plane_count > 1 and false for control_plane_count = 1."
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
  description = "Additional tags applied to every Azure resource this module creates, and forwarded to cloud-init's platform Application (helm.valuesObject.extraTags)."
  type        = map(string)
  default     = {}
}

# ---- Azure-specific inputs ----
variable "resource_group_name" {
  description = "Azure resource group to create every control-plane resource in (VMs, NICs, NSG, ASGs, load balancer, Key Vault)."
  type        = string
}

variable "location" {
  description = "Azure region for all resources (e.g. 'eastus', 'westeurope')."
  type        = string
}

variable "vnet_name" {
  description = "Name of the existing VNet control-plane NICs attach to. The module never creates VNets — pass an existing one."
  type        = string
}

variable "subnet_name" {
  description = "Name of the existing subnet within vnet_name. Azure has no default VNet, so this is required."
  type        = string
}

variable "network_resource_group_name" {
  description = "Resource group containing the VNet. Defaults to resource_group_name. Override for hub-spoke architectures where networking lives in a separate RG."
  type        = string
  default     = null
}

variable "vm_size" {
  description = "Azure VM SKU (bundles vCPU + memory, e.g. 'Standard_D4s_v3' for x86_64, 'Standard_D4ps_v5' for arm64) for every control-plane VM."
  type        = string
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB per control-plane VM."
  type        = number
  default     = 50
}

variable "os_disk_type" {
  description = "Azure managed disk type for the OS disk (e.g. 'Premium_LRS', 'Standard_LRS')."
  type        = string
  default     = "Premium_LRS"
}

variable "os_image_urn" {
  description = "Azure Marketplace image URN in Publisher:Offer:SKU:Version format. The tested OS is AlmaLinux 9. Null = almalinux:almalinux-x86_64:9-gen2:latest. For arm64, pass almalinux:almalinux-arm:9-arm-gen2:latest (or another arm64-compatible SKU) explicitly. AlmaLinux's Marketplace listing requires one-time-per-subscription terms acceptance (`az vm image terms accept`) before first deploy — not automated by this module."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "OS admin user created by Azure at VM provisioning. Never reachable — port 22 is denied at NSG priority 100."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for the admin user (content, not path), applied to every control-plane VM. Azure requires a key for Linux VMs with password auth disabled; the NSG denies port 22 so this key can never be used to log in remotely."
  type        = string
}

variable "node_arch" {
  description = "CPU architecture of the control-plane VMs ('x86_64' or 'arm64'). Declared explicitly — Azure SKU architecture is not trivially queryable from HCL. Ensure vm_size and os_image_urn match."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.node_arch)
    error_message = "node_arch must be 'x86_64' or 'arm64'."
  }
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports — the networks you administer/reach the cluster from. Required — environment-specific."
  type        = list(string)
  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "At least one CIDR block is required."
  }
}

variable "ingress_ports" {
  description = "TCP ports to open inbound from allowed_ingress_cidrs on every control-plane VM. Port 22 is always denied regardless of this list. Port order is stable — removing or reordering entries changes NSG rule priorities (200, 210, 220, ...) and triggers rule recreation."
  type        = list(number)
  default     = [80, 443, 6443]
  validation {
    condition     = !contains(var.ingress_ports, 22)
    error_message = "Port 22 (SSH) must not be in ingress_ports — access is via az vm run-command, not SSH."
  }
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

variable "availability_zones" {
  description = "Azure availability zones control-plane VMs are spread across, cycling round-robin by index (VM i lands in zone availability_zones[i % length(availability_zones)]). Required to have at least 3 distinct entries when control_plane_count > 1 — enforced at plan time via a resource precondition, matching aws-control-plane's >= 3 distinct AZ requirement."
  type        = list(string)
  default     = ["1", "2", "3"]
}

variable "cluster_domain" {
  description = "Optional DNS suffix (e.g. 'example.com'). When set, FQDN = api.<cluster_name>.<cluster_domain> and wildcard = *.<cluster_name>.<cluster_domain>. When dns_zone_resource_group is also set, a wildcard A record is created in the Azure DNS zone matching cluster_domain."
  type        = string
  default     = null
}

variable "dns_zone_resource_group" {
  description = "Resource group containing the Azure DNS zone for cluster_domain. When set (together with cluster_domain), a wildcard A record is created. Null = no DNS record created; register wildcard_dns_name at cluster_ip/registration_address yourself."
  type        = string
  default     = null
}
