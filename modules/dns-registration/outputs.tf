# SPDX-License-Identifier: Apache-2.0

output "fqdn" {
  description = "The fully-qualified name this module registered (record_name + dns_zone)."
  value       = "${var.record_name}.${var.dns_zone}"
}

output "record_created" {
  description = "Whether a dns_a_record_set resource was actually created this run (mirrors var.enabled)."
  value       = length(dns_a_record_set.this) > 0
}
