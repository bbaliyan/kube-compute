# SPDX-License-Identifier: Apache-2.0

variable "dns_server_address" {
  description = "Hostname or IPv4 address of the RFC2136-compliant DNS server to send the dynamic update to (any server that speaks RFC2136 — not tied to a specific product)."
  type        = string
}

variable "dns_server_port" {
  description = "UDP/TCP port the DNS server accepts dynamic updates on."
  type        = number
  default     = 53
}

variable "dns_transport" {
  description = "Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. TCP is the default here — more reliable than UDP for a record set that can carry several addresses."
  type        = string
  default     = "tcp"
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.dns_transport)
    error_message = "dns_transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
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

variable "tsig_key_name" {
  description = "Name of the TSIG key configured on the DNS server, used to authenticate this update."
  type        = string
}

variable "tsig_key_algorithm" {
  description = "TSIG key algorithm: 'hmac-md5', 'hmac-sha1', 'hmac-sha256', or 'hmac-sha512'. Must match how the key was created on the DNS server."
  type        = string
  default     = "hmac-sha256"
  validation {
    condition     = contains(["hmac-md5", "hmac-sha1", "hmac-sha256", "hmac-sha512"], var.tsig_key_algorithm)
    error_message = "tsig_key_algorithm must be one of: hmac-md5, hmac-sha1, hmac-sha256, hmac-sha512."
  }
}

variable "tsig_key_secret" {
  description = "Base64-encoded TSIG shared secret. Sensitive — supply via a TF_VAR_* environment variable, never committed."
  type        = string
  sensitive   = true
}
