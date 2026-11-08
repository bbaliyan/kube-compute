# SPDX-License-Identifier: Apache-2.0
output "data" {
  description = "The '#cloud-config' vendor data document, for a proxmox_virtual_environment_file snippet wired to initialization.vendor_data_file_id."
  value       = "#cloud-config\n${yamlencode(local.cloud_config)}"
}
