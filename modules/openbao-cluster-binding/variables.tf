# SPDX-License-Identifier: Apache-2.0

variable "cluster_name" {
  description = "Identity of the cluster (or vCluster) this binding is for. Used to derive the default auth mount path (kubernetes-<cluster_name>) and default secret path prefix (kube/<cluster_name>) unless overridden."
  type        = string
}

variable "kubernetes_host" {
  description = "API server URL of the target cluster (or vCluster) that OpenBao must trust for this binding."
  type        = string
}

variable "kubernetes_ca_cert" {
  description = "PEM-encoded CA certificate for kubernetes_host, used by OpenBao to verify the API server when validating logins."
  type        = string
}

variable "token_reviewer_jwt" {
  description = "Long-lived ServiceAccount token OpenBao uses to call the Kubernetes TokenReview API against kubernetes_host. Must belong to a ServiceAccount already bound to system:auth-delegator in the target cluster (created in Stage A, outside this module's scope). Sourced from a Secret-backed SA token, not an ad-hoc kubectl create token — see README."
  type        = string
  sensitive   = true
}

variable "vault_kv_mount" {
  description = "KV v2 mount path where this cluster's secrets live."
  type        = string
  default     = "secret"
}

variable "auth_mount_path" {
  description = "Override for the Kubernetes auth mount path. Null (the default) computes kubernetes-<cluster_name> — Vault/OpenBao's kubernetes auth method trusts only one kubernetes_host/CA pair per mount, so each cluster identity needs its own dedicated mount rather than sharing one."
  type        = string
  default     = null
}

variable "eso_service_account_name" {
  description = "Name of the ServiceAccount External Secrets Operator authenticates as when logging into this auth mount."
  type        = string
  default     = "external-secrets"
}

variable "eso_service_account_namespace" {
  description = "Namespace of the ServiceAccount External Secrets Operator authenticates as when logging into this auth mount."
  type        = string
  default     = "external-secrets"
}

variable "secret_path_prefix" {
  description = "Override for the KV path prefix this cluster's ExternalSecrets may read. Null (the default) computes kube/<cluster_name>."
  type        = string
  default     = null
}

variable "extra_secret_path_prefixes" {
  description = "Additional KV path prefixes this cluster's ExternalSecrets may read, granted read access alongside secret_path_prefix. For a consumer whose ExternalSecrets span more than one logical KV namespace — e.g. this cluster's own infra secrets under kube/<cluster_name>/* plus a separate GitOps workloads repo's own secrets under a different top-level prefix. Empty by default (single-prefix behavior, unchanged)."
  type        = list(string)
  default     = []
}

variable "role_name" {
  description = "Name of the Kubernetes auth backend role bound to the ESO ServiceAccount."
  type        = string
  default     = "eso-kube-apps"
}

variable "token_ttl_seconds" {
  description = "TTL, in seconds, of the OpenBao client token issued on successful login via this role. Not the reviewer JWT's own TTL."
  type        = number
  default     = 3600
}

variable "disable_iss_validation" {
  # RKE2's ServiceAccount token issuer defaults to a cluster-internal-only URL
  # (https://kubernetes.default.svc.cluster.local) that OpenBao, running outside
  # the cluster, cannot reach to fetch an OIDC discovery document — so issuer
  # validation must stay disabled and TokenReview is the only validation path.
  description = "Whether to disable OIDC issuer validation on this auth mount. Must stay true for RKE2 clusters (see comment above)."
  type        = bool
  default     = true
}
