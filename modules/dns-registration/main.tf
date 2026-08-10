# SPDX-License-Identifier: Apache-2.0

# The "dns" provider (TSIG server/port/transport/key) is configured by the
# CALLER and passed in via providers = {}, not here: Terraform forbids
# count/for_each/depends_on on a module call whose module owns its own
# provider config block ("legacy module"), and callers need depends_on to
# sequence this after their own bootstrap work. See README.
#
# One record set, every address under the same name — not one record per
# address. Sufficient because RKE2 agents self-discover peers after their
# first join, and kubectl already retries sequentially across resolved
# addresses; no health-checked updates needed.
resource "dns_a_record_set" "this" {
  count = var.enabled ? 1 : 0

  zone      = var.dns_zone
  name      = var.record_name
  addresses = var.record_addresses
  ttl       = var.record_ttl
}
