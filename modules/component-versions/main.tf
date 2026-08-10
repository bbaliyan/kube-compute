# SPDX-License-Identifier: Apache-2.0
# Single source of truth for the kube-platform pin. Not user-facing on its own —
# node-bootstrap reads this as the fallback default for the Argo CD Application's
# repo/revision instead of keeping its own copy.

locals {
  # Tracks kube-platform's protected `main` branch (required PR review before
  # merge), not a pinned commit SHA — see node-bootstrap's use of this for the
  # reproducibility/currency tradeoff that implies.
  pinned_platform_repo_url = "https://github.com/bbaliyan/kube-platform.git"
  pinned_platform_revision = "main"
}
