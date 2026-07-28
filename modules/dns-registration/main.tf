# SPDX-License-Identifier: Apache-2.0

locals {
  # The provider requires a fully-qualified (trailing-dot) TSIG key name, but
  # DNS servers commonly configure key names without one (e.g. Technitium's
  # own UI accepts a bare name like "kube-compute") — qualify here so callers
  # don't need to know this provider-specific quirk. Idempotent whether or
  # not var.tsig_key_name already ends in a dot.
  tsig_key_name_fqdn = "${trimsuffix(var.tsig_key_name, ".")}."
}

# Signs and sends the update itself — TSIG credentials configured here, not on
# the resource, per the hashicorp/dns provider's design (one signing identity
# per provider instance; a caller needing multiple DNS servers/keys would
# instantiate this module more than once with provider aliasing).
provider "dns" {
  update {
    server        = var.dns_server_address
    port          = var.dns_server_port
    transport     = var.dns_transport
    key_name      = local.tsig_key_name_fqdn
    key_algorithm = var.tsig_key_algorithm
    key_secret    = var.tsig_key_secret
  }
}

# One record set, every resolved address published under the same name — not
# one record per address. Clients (RKE2 agents, kubectl) resolve this name to
# all current addresses and pick one; see the design rationale this
# implements (a plain multi-address record is sufficient, no health-checked
# updates needed — RKE2 agents self-discover peers after their first join,
# kubectl already retries sequentially across resolved addresses).
resource "dns_a_record_set" "this" {
  zone      = var.dns_zone
  name      = var.record_name
  addresses = var.record_addresses
  ttl       = var.record_ttl
}
