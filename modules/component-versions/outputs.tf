# SPDX-License-Identifier: Apache-2.0
output "k8s_version" {
  description = "Default K3s release string used when a caller doesn't override k8s_version."
  value       = local.k8s_version
}

output "cilium_version" {
  description = "Default Cilium Helm chart version used when a caller doesn't override it."
  value       = local.cilium_version
}

output "argocd_version" {
  description = "Default Argo CD Helm chart version used when a caller doesn't override it."
  value       = local.argocd_version
}
