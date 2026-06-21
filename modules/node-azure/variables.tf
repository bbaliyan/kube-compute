# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (identical across all provider modules) ----

variable "cluster_name" {
  description = "Cluster identity. Used in resource names, tags, FQDN, and kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version string (e.g. v1.36.1+k3s1). Neutral name."
  type        = string
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

# ---- Azure-specific inputs ----

variable "resource_group_name" {
  description = "Azure resource group to create the VM and associated resources in."
  type        = string
}

variable "location" {
  description = "Azure region for all resources (e.g. 'eastus', 'westeurope')."
  type        = string
}

variable "vnet_name" {
  description = "Name of the existing VNet the VM NIC attaches to. The module never creates VNets — pass an existing one."
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
  description = "Azure VM SKU (bundles vCPU + memory, e.g. 'Standard_D4s_v3' for x86_64, 'Standard_D4ps_v5' for arm64). The operator picks a SKU matching their node_arch."
  type        = string
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB."
  type        = number
  default     = 50
}

variable "os_disk_type" {
  description = "Azure managed disk type for the OS disk (e.g. 'Premium_LRS', 'Standard_LRS')."
  type        = string
  default     = "Premium_LRS"
}

variable "os_image_urn" {
  description = "Azure Marketplace image URN in Publisher:Offer:SKU:Version format (e.g. 'MicrosoftCBLMariner:azure-linux:azure-linux-4-gen2:latest'). MUST be a RHEL-family image — cloud-init uses dnf and update-ca-trust. Null = Azure Linux 4 gen2 (x86_64). For arm64, pass the arm64 SKU explicitly."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "OS admin user created by Azure at VM provisioning. Azure requires an admin account even when SSH is blocked by NSG. The account is never reachable — port 22 is denied at priority 100."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for the admin user (content, not path). Azure requires a key for Linux VMs with password auth disabled. The NSG denies port 22 — this key can never be used to log in remotely."
  type        = string
}

variable "vm_private_ip" {
  description = "Static private IPv4 address within the subnet (e.g. '10.0.1.10'). Null = dynamic allocation (DHCP). Static IP is strongly recommended: known at plan time, DNS entries stable across restarts."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports. Required — environment-specific (your admin network, VPN, etc.)."
  type        = list(string)
  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0
    error_message = "At least one CIDR block is required."
  }
}

variable "ingress_ports" {
  description = "TCP ports to open inbound from allowed_ingress_cidrs. Port 22 is always denied regardless of this list. Port order is stable — removing or reordering entries will change rule priorities and trigger rule recreation."
  type        = list(number)
  default     = [80, 443, 6443]
  validation {
    condition     = !contains(var.ingress_ports, 22)
    error_message = "Port 22 (SSH) must not be in ingress_ports — access is via Azure run-command, not SSH."
  }
}

variable "cluster_domain" {
  description = "Optional DNS suffix (e.g. 'example.com'). When set, FQDN = api.<cluster_name>.<cluster_domain> and wildcard = *.<cluster_name>.<cluster_domain>. When dns_zone_resource_group is also set, a wildcard A record is created in the Azure DNS zone matching cluster_domain."
  type        = string
  default     = null
}

variable "dns_zone_resource_group" {
  description = "Resource group containing the Azure DNS zone for cluster_domain. When set (together with cluster_domain), a wildcard A record is created. Null = no DNS record created; register wildcard_dns_name at cluster_ip yourself."
  type        = string
  default     = null
}

variable "node_arch" {
  description = "CPU architecture of the VM ('x86_64' or 'arm64'). Declared explicitly — Azure SKU architecture is not trivially queryable from HCL. Ensure vm_size and os_image_urn match this value."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.node_arch)
    error_message = "node_arch must be 'x86_64' or 'arm64'."
  }
}
