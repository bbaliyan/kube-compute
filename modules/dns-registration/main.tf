# SPDX-License-Identifier: Apache-2.0

# The "dns" provider itself (TSIG server/port/transport/key config) is
# configured by the CALLER and passed in via this module call's providers =
# {} argument, not here. Terraform forbids count/for_each/depends_on on a
# module call whose module owns its own provider configuration block ("legacy
# module") — a caller needing depends_on (to sequence this after its own
# bootstrap work succeeds) can't get it if this module configures "dns"
# itself, so that configuration lives one level up. See README.
#
# One record set, every resolved address published under the same name — not
# one record per address. Clients (RKE2 agents, kubectl) resolve this name to
# all current addresses and pick one; see the design rationale this
# implements (a plain multi-address record is sufficient, no health-checked
# updates needed — RKE2 agents self-discover peers after their first join,
# kubectl already retries sequentially across resolved addresses).
resource "dns_a_record_set" "this" {
  count = var.enabled ? 1 : 0

  zone      = var.dns_zone
  name      = var.record_name
  addresses = var.record_addresses
  ttl       = var.record_ttl
}
