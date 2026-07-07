# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to node-bootstrap) ----
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Defaults to the bundled Ubuntu 26.04 LTS template."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Cluster identity this pool joins. Must match the spine's cluster_name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version this pool's workers install. Must not be newer than spine_k8s_version."
  type        = string
  default     = "v1.36.1+k3s1"
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

variable "extra_tags" {
  description = "Additional tags applied to every Azure resource this module creates."
  type        = map(string)
  default     = {}
}

# ---- Azure-specific inputs (mirrors spine-azure/node-azure) ----
variable "resource_group_name" {
  description = "Azure resource group to create every pool resource in (VM Scale Set, role assignment)."
  type        = string
}

variable "location" {
  description = "Azure region for the pool. Must match the spine's region."
  type        = string
}

variable "vnet_name" {
  description = "Name of the existing VNet the pool's NICs attach to."
  type        = string
}

variable "subnet_name" {
  description = "Name of the existing subnet within vnet_name."
  type        = string
}

variable "network_resource_group_name" {
  description = "Resource group containing the VNet. Defaults to resource_group_name."
  type        = string
  default     = null
}

variable "vm_size" {
  description = "Azure VM SKU for every worker in this pool."
  type        = string
}

variable "os_disk_size_gb" {
  description = "OS disk size in GiB per worker."
  type        = number
  default     = 50
}

variable "os_disk_type" {
  description = "Azure managed disk type for the OS disk."
  type        = string
  default     = "Premium_LRS"
}

variable "os_image_urn" {
  description = "Azure Marketplace image URN. Null = Ubuntu 26.04 LTS gen2 (x86_64)."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "OS admin user created by Azure. Never reachable — no inbound NSG on this pool's NICs beyond the spine-owned cluster ASG rule."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for the admin user, applied to every worker VM in this pool."
  type        = string
}

variable "zone" {
  description = "Single Azure availability zone this pool is pinned to (one pool = one zone, matching worker-pool-aws's one-pool-per-subnet-per-AZ convention). The module never spreads one pool across zones."
  type        = string
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

variable "spine_k8s_version" {
  description = "The spine's k8s_version output. This pool's k8s_version is rejected if it is newer."
  type        = string
}

variable "registration_address" {
  description = "The spine's registration_address output. Workers join via --server https://<this>:6443."
  type        = string
}

variable "key_vault_id" {
  description = "The spine's key_vault_id output. This pool's role assignment is scoped under this vault at the individual-secret level (key_vault_id + /secrets/ + agent_token_secret_name)."
  type        = string
}

variable "key_vault_name" {
  description = "The spine's key_vault_name output. Used to build the vault URI in the agent token fetch command."
  type        = string
}

variable "agent_token_secret_name" {
  description = "The spine's agent_token_secret_name output. This pool's managed identity is granted read access scoped to exactly this one secret."
  type        = string
}

variable "cluster_asg_id" {
  description = "The spine's cluster_asg_id output. Every worker NIC joins this Application Security Group for east-west cluster access; this module owns no other ASG."
  type        = string
}

variable "extra_node_labels" {
  description = "Additional --node-label flags beyond the automatic AZ label (topology.kubernetes.io/zone) this module always sets from var.zone."
  type        = map(string)
  default     = {}
}
