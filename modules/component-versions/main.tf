# SPDX-License-Identifier: Apache-2.0
# Single source of truth for default software versions shared across every
# control-plane-*/node-pool-* module and cloud-init. Not user-facing on its own —
# callers reference these as fallback defaults (coalesce(var.x, module.component_versions.x)),
# so a version bump here propagates everywhere without hunting down each
# module's own copy of the same literal.

locals {
  # renovate: datasource=github-releases depName=k3s-io/k3s
  k8s_version = "v1.36.1+k3s1"

  # renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io/
  cilium_version = "1.19.5"

  # renovate: datasource=helm depName=argo-cd registryUrl=https://argoproj.github.io/argo-helm
  argocd_version = "10.1.3"
}
