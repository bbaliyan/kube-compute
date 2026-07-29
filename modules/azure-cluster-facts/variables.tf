# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster identity. Used in the Key Vault name and ASG name/tags."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version to install. Null falls back to the platform default from component-versions (via the shared cluster-facts core)."
  type        = string
  default     = null
}

variable "resource_group_name" {
  description = "Azure resource group to create the Key Vault and Application Security Group in. Unlike azure-control-plane (which requires this too), this module has no other context to derive it from — the caller must resolve/create the resource group before this module runs, since this module applies before control-plane."
  type        = string
}

variable "location" {
  description = "Azure region for the Key Vault and ASG (e.g. 'eastus', 'westeurope')."
  type        = string
}

variable "extra_tags" {
  description = "Additional tags applied to the Key Vault and ASG, matching azure-control-plane's own extra_tags/common_tags convention."
  type        = map(string)
  default     = {}
}
