# SPDX-License-Identifier: Apache-2.0
output "steps" {
  description = "Value for node-bootstrap's provider_steps."
  value       = local.steps
}

output "files" {
  description = "Value for node-bootstrap's provider_files. Sensitive: it carries the TSIG key."
  value       = local.files
  sensitive   = true
}
