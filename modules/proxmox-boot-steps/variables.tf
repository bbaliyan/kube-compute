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

variable "iscsi_initiator_enabled" {
  description = "Write a deterministic iSCSI InitiatorName (iqn.2026.lan.<cluster_name>:<node_fqdn_label, or node_name if unset>) to /etc/iscsi/initiatorname.iscsi and restart iscsid, replacing the OS-generated random one. The image must already have iscsi-initiator-utils (kube-images' Proxmox template does). Exists so an iSCSI target's initiator allow-list can be registered once, ahead of time, and not re-registered by hand after every VM rebuild."
  type        = bool
  default     = true
}

variable "dns_self_register_zone" {
  description = "DNS zone (FQDN, trailing dot, e.g. 'lan.') the genesis node self-registers a single-target A record into via RFC2136/nsupdate, as soon as it knows its own IP. Null or empty (the default) disables self-registration, and every dns_self_register_*, dns_server_* and tsig_* variable is then ignored. Set it on the genesis node only."
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
  description = "TTL in seconds for the self-registered record. Only meaningful when dns_self_register_zone is set. Kept low by default: this record is republished on every apply via authoritative RFC2136 update, but a downstream caching resolver (e.g. a LAN router forwarding to the authoritative server) has no way to know that and keeps serving whatever it last cached for up to this TTL — on a reused cluster/record name that stale window directly delays every joining node."
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
