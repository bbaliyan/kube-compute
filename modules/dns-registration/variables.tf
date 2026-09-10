# SPDX-License-Identifier: Apache-2.0

variable "enabled" {
  description = "Whether to publish the record. false is a no-op (no resource created)."
  type        = bool
  default     = true
}

variable "dns_zone" {
  description = "DNS zone the record belongs to. Must be an FQDN including the trailing dot (e.g. 'lan.')."
  type        = string
}

variable "record_name" {
  description = "Record name, relative to dns_zone (e.g. 'api.cluster-3' for zone 'lan.' registers 'api.cluster-3.lan.')."
  type        = string
}

variable "record_addresses" {
  description = "IPv4 addresses this record should resolve to. A record set, not one record per address — every address is published under the same name."
  type        = list(string)
}

variable "record_ttl" {
  description = "TTL in seconds for the record."
  type        = number
  default     = 300
}

variable "dns_server_address" {
  description = "Hostname or IPv4 address of the RFC2136-compliant DNS server to publish to."
  type        = string
}

variable "dns_server_port" {
  description = "Port the DNS server accepts dynamic updates on."
  type        = number
  default     = 53
}

variable "dns_transport" {
  description = "Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'."
  type        = string
  default     = "udp"
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.dns_transport)
    error_message = "dns_transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
}

variable "tsig_key_name" {
  description = "Name of the TSIG key configured on the DNS server, used to authenticate the dynamic update."
  type        = string
}

variable "tsig_key_algorithm" {
  description = "TSIG key algorithm: 'hmac-md5', 'hmac-sha1', 'hmac-sha256', or 'hmac-sha512'. Must match how the key was created on the DNS server."
  type        = string
  validation {
    condition     = contains(["hmac-md5", "hmac-sha1", "hmac-sha256", "hmac-sha512"], var.tsig_key_algorithm)
    error_message = "tsig_key_algorithm must be one of: hmac-md5, hmac-sha1, hmac-sha256, hmac-sha512."
  }
}

variable "tsig_key_secret" {
  description = "Base64-encoded TSIG shared secret. Sensitive — supply via a TF_VAR_* environment variable, never committed. Deliberately kept out of every tracked resource attribute (see README) so it never lands in state; passed to nsupdate only as a process environment variable at apply/destroy time."
  type        = string
  sensitive   = true
}
