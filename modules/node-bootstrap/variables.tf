# SPDX-License-Identifier: Apache-2.0
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Use the bundled templates for AL2023 or Ubuntu 26.04 LTS, or supply your own path for other distributions. No compatibility guarantee is made for untested distributions."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name. Drives the kubeconfig server SAN and status reporting."
  type        = string
}

variable "k8s_version" {
  description = "K8s distro version to install (a K3s release string today, e.g. v1.36.1+k3s1). Neutral name so a future distro hop does not change the interface."
  type        = string
  default     = "v1.36.1+k3s1"
}

variable "cluster_fqdn" {
  description = "Optional DNS name for the API/kubeconfig server and an extra TLS SAN. Null = use the node IP only. This is just a name string; how it resolves (managed DNS, a local resolver, or none) is the caller's concern."
  type        = string
  default     = null
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) to add to the OS trust store via update-ca-trust. Effect, not use case: a private/corp/homelab CA, or null to skip. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream registries directly."
  type        = string
  default     = null
}

variable "gitops_platform_repo_url" {
  description = "Optional Argo CD platform Application source repo (kube-platform or a fork). Null = skip all Argo CD wiring."
  type        = string
  default     = null
}

variable "gitops_platform_revision" {
  description = "Branch/tag/SHA the platform Application tracks."
  type        = string
  default     = "main"
}

variable "gitops_workloads_repo_url" {
  description = "Optional user workloads Application source repo. Null = no workloads Application."
  type        = string
  default     = null
}

variable "gitops_workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks."
  type        = string
  default     = "main"
}

variable "gitops_workloads_path" {
  description = "Path within the workloads repo the ApplicationSet scans. Config (not convention) because we do not control that repo."
  type        = string
  default     = "apps"
}

variable "cert_mode" {
  description = "Certificate issuer mode deployed by kube-platform. 'selfsigned' needs no dependencies. 'byo' expects a Secret named byo-ca-tls in the cert-manager namespace. 'acme' requires DNS-01 config (separate setup)."
  type        = string
  default     = "selfsigned"
  validation {
    condition     = contains(["selfsigned", "byo", "acme"], var.cert_mode)
    error_message = "cert_mode must be 'selfsigned', 'byo', or 'acme'."
  }
}

variable "platform_extra_helm_parameters" {
  description = "Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. Use for optional platform features (secret store wiring, future extensions) without requiring node-bootstrap changes."
  type        = map(string)
  default     = {}
}

variable "platform_helm_values_object" {
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject. Use for nested values that cannot be expressed as flat helm.parameters strings."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional tags forwarded to the platform bootstrap Application (as part of helm.valuesObject.extraTags) so Kubernetes-managed resources, e.g. CSI-provisioned storage, can tag themselves consistently with the node's own tags."
  type        = map(string)
  default     = {}
}
