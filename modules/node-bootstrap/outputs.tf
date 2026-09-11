# SPDX-License-Identifier: Apache-2.0
output "cloud_init_user_data" {
  description = "Complete '#cloud-config' document for this one node: hostname, the RKE2 config/registries/CA/manifest payloads as base64 write_files, and a runcmd invoking the bootstrap script. The caller delivers it verbatim as its provider's user-data (on Proxmox, a proxmox_virtual_environment_file snippet wired to initialization.user_data_file_id). This module executes nothing itself — there is no bootstrap resource to depend on; a caller needing ordering must depend on its own VM resource instead. Sensitive: carries the join tokens, trusted CA, and TSIG secret."
  value       = local.cloud_init_user_data
  sensitive   = true
}

output "node_setup_script" {
  description = "The same payload as cloud_init_user_data as a shell script: hostname, the same write_files with the same modes and owners, then bootstrap.sh. For callers whose platform caps user data (EC2 allows 16384 decoded bytes) -- store this out of band and boot a stub that fetches and runs it. Sensitive for the same reasons as cloud_init_user_data."
  value       = local.node_setup_script
  sensitive   = true
}

output "node_name" {
  description = "Node name this payload was rendered for — the OS hostname it sets, and therefore the Kubernetes node name RKE2/kubelet will register. Echoed back so a caller can key snippet filenames off the same value without recomputing it."
  value       = var.node_name
}
