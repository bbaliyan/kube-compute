# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster name. Part of the iSCSI initiator name."
  type        = string
}

variable "node_name" {
  description = "Node name. Names the iSCSI initiator when node_fqdn_label is null."
  type        = string
}

variable "node_fqdn_label" {
  description = "Short label that names the iSCSI initiator. Null uses node_name."
  type        = string
  default     = null
}

variable "iscsi_initiator_prefix" {
  description = "Prefix of the fixed iSCSI initiator name, in the form iqn.<yyyy-mm>.<reversed domain>, for example iqn.2026-01.test.example. A node writes <prefix>:<cluster_name>-<node label>, so a target can allow-list it before a rebuild. Null keeps the OS name. The image needs iscsi-initiator-utils."
  type        = string
  default     = null
  validation {
    condition     = var.iscsi_initiator_prefix == null || can(regex("^iqn[.][0-9]{4}-(0[1-9]|1[0-2])[.][a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.iscsi_initiator_prefix))
    error_message = "iscsi_initiator_prefix must look like iqn.2026-01.test.example (iqn, year-month, reversed domain in lowercase)."
  }
}

variable "dns_self_register_zone" {
  description = "DNS zone (FQDN, trailing dot, e.g. 'lan.') the genesis node registers a single-target A record in through RFC2136 nsupdate. Null or empty (the default) disables it, and every dns_self_register_*, dns_server_* and tsig_* variable is ignored. Set it on the genesis node only."
  type        = string
  default     = null
}

variable "dns_self_register_record_name" {
  description = "Record name, relative to dns_self_register_zone (e.g. 'genesis.my-cluster' for zone 'example.test.' registers 'genesis.my-cluster.example.test.'). Required when dns_self_register_zone is set; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.dns_self_register_record_name != null
    error_message = "dns_self_register_record_name is required when dns_self_register_zone is set."
  }
}

variable "dns_self_register_ttl" {
  description = "TTL in seconds for the self-registered record. Used only when dns_self_register_zone is set. Keep it low: a downstream caching resolver serves a stale record for up to this TTL."
  type        = number
  default     = 30
}

variable "dns_server_address" {
  description = "RFC2136 DNS server address the genesis node sends its nsupdate request to. Required when dns_self_register_zone is set; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.dns_server_address != null
    error_message = "dns_server_address is required when dns_self_register_zone is set."
  }
}

variable "dns_server_port" {
  description = "RFC2136 DNS server port. Only meaningful when dns_self_register_zone is set."
  type        = number
  default     = 53
}

variable "dns_transport" {
  description = "Transport nsupdate uses to reach dns_server_address: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Only meaningful when dns_self_register_zone is set."
  type        = string
  default     = "udp"
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.dns_transport)
    error_message = "dns_transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
}

variable "tsig_key_name" {
  description = "TSIG key name authorizing the nsupdate request. Required when dns_self_register_zone is set; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.tsig_key_name != null
    error_message = "tsig_key_name is required when dns_self_register_zone is set."
  }
}

variable "tsig_key_algorithm" {
  description = "TSIG key algorithm (e.g. 'hmac-sha256'). Only meaningful when dns_self_register_zone is set."
  type        = string
  default     = "hmac-sha256"
}

variable "tsig_key_secret" {
  description = "Base64-encoded TSIG key secret. Required when dns_self_register_zone is set; ignored otherwise. Sensitive: cloud-init writes it to a 0600 key file that the step removes after nsupdate."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = (var.dns_self_register_zone == null || var.dns_self_register_zone == "") || var.tsig_key_secret != null
    error_message = "tsig_key_secret is required when dns_self_register_zone is set."
  }
}
