# SPDX-License-Identifier: Apache-2.0
# Single source of truth for default software versions shared across every
# control-plane-*/node-pool-* module and cloud-init. Not user-facing on its own —
# callers reference these as fallback defaults (coalesce(var.x, module.component_versions.x)),
# so a version bump here propagates everywhere without hunting down each
# module's own copy of the same literal.

locals {
  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io/
  cilium_version = "1.19.5"

  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  argocd_version = "10.3.2"

  # Single source of truth for the kube-platform pin — node-bootstrap reads it
  # for the Argo CD Application's repo/revision instead of keeping its own
  # copy. Tracks kube-platform's protected `main` branch (required PR review
  # before merge), not a pinned commit SHA — see node-bootstrap's use of this
  # for the reproducibility/currency tradeoff that implies.
  pinned_platform_repo_url = "https://github.com/bbaliyan/kube-platform.git"
  pinned_platform_revision = "main"
}
