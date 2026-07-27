# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to node-bootstrap) ----
variable "ansible_playbook_path" {
  description = "Absolute path to the Ansible playbook node-bootstrap runs. Defaults to the bundled AlmaLinux-10-only playbook. Override only for a consumer-supplied playbook targeting a different OS (no compatibility guarantee)."
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

variable "extra_tags" {
  description = "Additional tags applied to every Azure resource this module creates."
  type        = map(string)
  default     = {}
}

# ---- Azure-specific inputs (mirrors azure-control-plane/node-azure) ----
variable "resource_group_name" {
  description = "Azure resource group to create every pool resource in (VM Scale Set, role assignment)."
  type        = string
}

variable "location" {
  description = "Azure region for the pool. Must match the control plane's region."
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
  description = "Azure Marketplace image URN. Null = almalinux:almalinux-x86_64:10-gen2:latest. Requires one-time-per-subscription Marketplace terms acceptance (`az vm image terms accept`) before first deploy — not automated by this module."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "OS admin user created by Azure. Never reachable — this pool owns its own NSG, which denies inbound SSH on every worker NIC."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for the admin user, applied to every worker VM in this pool."
  type        = string
}

variable "zone" {
  description = "Single Azure availability zone this pool is pinned to (one pool = one zone, matching aws-node-pool's one-pool-per-subnet-per-AZ convention). The module never spreads one pool across zones."
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

variable "control_plane_k8s_version" {
  description = "The control plane's k8s_version output. This pool's k8s_version is rejected if it is newer."
  type        = string
}

variable "registration_address" {
  description = "The control plane's registration_address output. Workers join via config.yaml's server: https://<this>:9345 (RKE2's supervisor/join port, distinct from the 6443 Kubernetes API port)."
  type        = string
}

variable "key_vault_id" {
  description = "The control plane's key_vault_id output. This pool's role assignment is scoped under this vault at the individual-secret level (key_vault_id + /secrets/ + agent_token_secret_name)."
  type        = string
}

variable "key_vault_name" {
  description = "The control plane's key_vault_name output. Used to build the vault URI in the agent token fetch command."
  type        = string
}

variable "agent_token_secret_name" {
  description = "The control plane's agent_token_secret_name output. This pool's managed identity is granted read access scoped to exactly this one secret."
  type        = string
}

variable "cluster_asg_id" {
  description = "The control plane's cluster_asg_id output. Every worker NIC joins this Application Security Group for east-west cluster access; this module owns no other ASG."
  type        = string
}

variable "extra_node_labels" {
  description = "Additional node-label: entries beyond the automatic AZ label (topology.kubernetes.io/zone) this module always sets from var.zone."
  type        = map(string)
  default     = {}
}
