# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster identity. Used to derive the ipset naming convention."
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
