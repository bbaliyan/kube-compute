# SPDX-License-Identifier: Apache-2.0

output "fqdn" {
  description = "The fully-qualified name this module registered (record_name + dns_zone)."
  value       = "${var.record_name}.${var.dns_zone}"
}
