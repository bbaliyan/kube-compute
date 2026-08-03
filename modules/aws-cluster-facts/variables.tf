# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster identity. Used in the SSM parameter path and security group name/tags."
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

variable "vpc_id" {
  description = "VPC ID the cluster security group belongs to. Unlike aws-control-plane (which can default to the account's default VPC for a single-node cluster), this module has no subnet/AMI context to derive a default VPC from, so one of vpc_id or vpc_name is required. Alternative to vpc_name — pass the literal ID."
  type        = string
  default     = null
}

variable "vpc_name" {
  description = "Name tag of the VPC. Alternative to vpc_id — the module resolves the ID via a data lookup, mirroring aws-control-plane's own vpc_name lookup. Ignored when vpc_id is set."
  type        = string
  default     = null

  validation {
    condition     = var.vpc_id != null || var.vpc_name != null
    error_message = "One of vpc_id or vpc_name is required — this module has no default-VPC fallback (see vpc_id's description)."
  }
}

variable "extra_tags" {
  description = "Additional tags applied to the security group, matching aws-control-plane's own extra_tags convention."
  type        = map(string)
  default     = {}
}

# ---- GitOps config surface: pass-through to the shared cluster-facts core (see
# its variables.tf for the full description of each) ----

variable "platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. Passed straight through to cluster-facts."
  type        = bool
  default     = true
}

variable "platform_repo_url_override" {
  description = "Override for kube-platform's repo URL. Null means: use node-bootstrap's own pinned default. Passed straight through to cluster-facts."
  type        = string
  default     = null
}

variable "platform_revision_override" {
  description = "Override for the branch/tag/SHA the platform Application tracks. Null means: use node-bootstrap's own pinned default. Passed straight through to cluster-facts."
  type        = string
  default     = null
}

variable "workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo. Null (the default) = no workloads Application. Passed straight through to cluster-facts."
  type        = string
  default     = null
}

variable "workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Only meaningful when workloads_repo_url is set. Passed straight through to cluster-facts."
  type        = string
  default     = "main"
}

variable "workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Only meaningful when workloads_repo_url is set. Passed straight through to cluster-facts."
  type        = string
  default     = "."
}
