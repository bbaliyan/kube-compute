# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "Cluster identity. Used in the names of the IAM roles and in tags. Lowercase, starts with a letter or digit."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter or digit, max 31 chars."
  }
}

variable "aws_region" {
  description = "Region of the cluster. The External Secrets role reads SSM parameters here, unless external_secrets_ssm_region is set."
  type        = string
}

variable "tags" {
  description = "Tags for every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "autoscaling_enabled" {
  description = "Create the cluster-autoscaler role. Set it to true when the cluster has autoscaled nodes. It is a flag, not a list check, because the group ARNs are not known at plan time."
  type        = bool
  default     = false
}

variable "autoscaling_group_arns" {
  description = "ARNs of the autoscaling groups that the cluster-autoscaler role may scale. Used only when autoscaling_enabled is true."
  type        = list(string)
  default     = []
}

variable "external_dns_hosted_zone_ids" {
  description = "Route53 hosted zone IDs that external-dns may change. An empty list creates no external-dns role: the consumer keeps its own policy."
  type        = list(string)
  default     = []
}

variable "external_dns_record_name_patterns" {
  description = "Record names that external-dns may change, matched with StringLike so * works inside a pattern, such as sql*.example.com. Use lower case with no trailing dot, and write a wildcard label as \\052. An empty list allows every record in the zones."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for pattern in var.external_dns_record_name_patterns : length(trimspace(pattern)) > 0])
    error_message = "Every external_dns_record_name_patterns entry must be a non-empty string."
  }
}

variable "external_secrets_ssm_path_prefixes" {
  description = "SSM parameter path prefixes that External Secrets may read, such as /platform/. Each must start with a slash. An empty list creates no External Secrets role."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for prefix in var.external_secrets_ssm_path_prefixes : startswith(prefix, "/")])
    error_message = "Every external_secrets_ssm_path_prefixes entry must start with a slash."
  }
}

variable "external_secrets_ssm_region" {
  description = "Region of the SSM parameters that the External Secrets role may read. Null uses aws_region."
  type        = string
  default     = null
}

variable "service_accounts" {
  description = "Namespace and name of the service account each role trusts. The defaults are the names the kube-platform charts create. Override a workload only if your chart values rename its service account."
  type = object({
    ebs_csi = optional(object({
      namespace = optional(string, "kube-system")
      name      = optional(string, "ebs-csi-controller-sa")
    }), {})
    cluster_autoscaler = optional(object({
      namespace = optional(string, "cluster-autoscaler")
      name      = optional(string, "cluster-autoscaler-aws-cluster-autoscaler")
    }), {})
    external_dns = optional(object({
      namespace = optional(string, "external-dns")
      name      = optional(string, "external-dns")
    }), {})
    external_secrets = optional(object({
      namespace = optional(string, "external-secrets")
      name      = optional(string, "external-secrets")
    }), {})
  })
  default = {}
}
