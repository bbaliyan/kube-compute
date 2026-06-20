# SPDX-License-Identifier: Apache-2.0
output "cloud_init" {
  description = "Plaintext rendered cloud-config. Sensitive — may contain trusted_ca_pem. Exposed for tests and debugging."
  value       = local.cloud_init
  sensitive   = true
}

output "user_data_base64" {
  description = "base64gzip of the rendered cloud-config, for VM user-data attachment (exceeds size limits uncompressed)."
  value       = base64gzip(local.cloud_init)
  sensitive   = true
}
