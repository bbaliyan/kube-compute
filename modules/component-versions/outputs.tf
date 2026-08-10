# SPDX-License-Identifier: Apache-2.0
output "cilium_version" {
  description = "Default Cilium Helm chart version used when a caller doesn't override it."
  value       = local.cilium_version
}

output "argocd_version" {
  description = "Default Argo CD Helm chart version used when a caller doesn't override it."
  value       = local.argocd_version
}

output "pinned_platform_repo_url" {
  description = "kube-platform repo URL every module falls back to when a caller doesn't override it — the single source of truth for the pin."
  value       = local.pinned_platform_repo_url
}

output "pinned_platform_revision" {
  description = "kube-platform branch/tag/SHA every module falls back to when a caller doesn't override it — the single source of truth for the pin."
  value       = local.pinned_platform_revision
}
