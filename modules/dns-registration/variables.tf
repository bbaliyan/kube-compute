# SPDX-License-Identifier: Apache-2.0

variable "enabled" {
  description = "Whether to publish the record. false is a no-op (no resource created) — lets a caller skip DNS registration without wrapping this module call in count/for_each, which it can't accept alongside depends_on (see the caller's provider \"dns\" block for why)."
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
