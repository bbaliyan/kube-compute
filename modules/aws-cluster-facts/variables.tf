# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster identity. Used in the SSM parameter path and security group name/tags."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
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
