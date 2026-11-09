# SPDX-License-Identifier: Apache-2.0
output "cloud_init_user_data" {
  description = "Complete '#cloud-config' document for this one node: hostname, the RKE2 config/registries/CA/manifest payloads as base64 write_files, and a runcmd invoking the bootstrap script. The caller delivers it verbatim as its provider's user-data (on Proxmox, a proxmox_virtual_environment_file snippet wired to initialization.user_data_file_id). This module executes nothing itself — there is no bootstrap resource to depend on; a caller needing ordering must depend on its own VM resource instead. Sensitive: carries the join tokens, trusted CA, and TSIG secret."
  value       = local.cloud_init_user_data
  sensitive   = true

  precondition {
    condition     = !local.render_argocd || (var.argocd_manifest_url != null && var.argocd_manifest_sha256 != null)
    error_message = "argocd_manifest_url and argocd_manifest_sha256 are required on the first server while a platform or workloads Application is enabled. Set both to a kube-platform release's argocd-bootstrap.yaml and its sha256."
  }
}

output "node_name" {
  description = "Node name this payload was rendered for — the OS hostname it sets, and therefore the Kubernetes node name RKE2/kubelet will register. Echoed back so a caller can key snippet filenames off the same value without recomputing it."
  value       = var.node_name
}

output "user_data" {
  description = "The final user data for this node: cloud_init_user_data alone when there are no boot scripts and no SSM Agent part, otherwise a MIME multipart/mixed document with those shell-script parts ahead of the cloud-config. The caller delivers it verbatim (gzip and base64 it for EC2). Sensitive, for the same reasons as cloud_init_user_data."
  value       = local.user_data

  precondition {
    condition     = !local.render_argocd || (var.argocd_manifest_url != null && var.argocd_manifest_sha256 != null)
    error_message = "argocd_manifest_url and argocd_manifest_sha256 are required on the first server while a platform or workloads Application is enabled. Set both to a kube-platform release's argocd-bootstrap.yaml and its sha256."
  }
  sensitive = true
}
