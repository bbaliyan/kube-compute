# SPDX-License-Identifier: Apache-2.0
output "cloud_init_user_data" {
  description = "Complete '#cloud-config' document for this one node: hostname, the RKE2 config/registries/CA/manifest payloads as base64 write_files, and a runcmd invoking the bootstrap script. The caller delivers it verbatim as its provider's user-data (on Proxmox, a proxmox_virtual_environment_file snippet wired to initialization.user_data_file_id). This module executes nothing itself — there is no bootstrap resource to depend on; a caller needing ordering must depend on its own VM resource instead. Sensitive: carries the join tokens, the trusted CA and any sensitive provider file."
  value       = local.cloud_init_user_data
  sensitive   = true

  precondition {
    condition     = !local.platform_clone_needed || local.boot_platform_repo_url != ""
    error_message = "gitops_platform_repo_url is required on the first server when gitops_platform_enabled is false and the node still needs Cilium or Argo CD: the first server clones that repo for bootstrap/rendered/. Set it to the platform repo, or use cni = \"default\" and no Application."
  }
}

output "node_name" {
  description = "Node name this payload was rendered for — the OS hostname it sets, and therefore the Kubernetes node name RKE2/kubelet will register. Echoed back so a caller can key snippet filenames off the same value without recomputing it."
  value       = var.node_name
}

output "user_data" {
  description = "The final user data for this node: cloud_init_user_data alone when there are no boot scripts, otherwise a MIME multipart/mixed document with those shell-script parts ahead of the cloud-config. The caller delivers it verbatim (gzip and base64 it for EC2). Sensitive, for the same reasons as cloud_init_user_data."
  value       = local.user_data

  precondition {
    condition     = !local.platform_clone_needed || local.boot_platform_repo_url != ""
    error_message = "gitops_platform_repo_url is required on the first server when gitops_platform_enabled is false and the node still needs Cilium or Argo CD: the first server clones that repo for bootstrap/rendered/. Set it to the platform repo, or use cni = \"default\" and no Application."
  }
  sensitive = true
}

output "boot_steps" {
  description = "Every step of this node's boot, in the order it runs: the provider steps, the module's cloud-init commands, the steps of the boot program, then the commands that follow it. The names say what the node does, so a test can assert the exact list."
  value       = local.boot_steps
}
