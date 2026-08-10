# SPDX-License-Identifier: Apache-2.0
# ---- GitOps config surface: the one place a consumer configures what a cluster
# runs, alongside the tokens above. control-plane threads these into genesis's
# node-bootstrap call; node-pool ignores them (they're only meaningful on the
# server-init node), same as it already ignores other control-plane-only outputs
# from this module. ----

variable "platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application. Passed straight through to node-bootstrap's gitops_platform_enabled."
  type        = bool
  default     = true
}

variable "platform_repo_url_override" {
  description = "Override for kube-platform's repo URL. Null (the default) means: use node-bootstrap's own pinned default rather than re-deriving the pin here — this module is not the source of truth for what version is pinned, only the place a consumer overrides it."
  type        = string
  default     = null
}

variable "platform_revision_override" {
  description = "Override for the branch/tag/SHA the platform Application tracks. Null (the default) means: use node-bootstrap's own pinned default. Only meaningful alongside platform_repo_url_override (setting one without the other is legal but unusual)."
  type        = string
  default     = null
}

variable "workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering — see node-bootstrap's workloads-app.yaml.j2). Null (the default) = no workloads Application at all; this stays opt-in, unlike platform."
  type        = string
  default     = null
}

variable "workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Only meaningful when workloads_repo_url is set."
  type        = string
  default     = "main"
}

variable "workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Only meaningful when workloads_repo_url is set."
  type        = string
  default     = "."
}
