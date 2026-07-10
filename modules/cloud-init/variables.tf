# SPDX-License-Identifier: Apache-2.0
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Use the bundled templates for AL2023 or Ubuntu 26.04 LTS, or supply your own path for other distributions. No compatibility guarantee is made for untested distributions."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name. Drives the kubeconfig server SAN and status reporting."
  type        = string
}

variable "node_name" {
  description = "Unique per-node hostname (e.g. '<cluster_name>-cp-0', '<cluster_name>-worker-1'). K3s/kubelet defaults the registered Kubernetes node name to the OS hostname, so every node in a multi-node cluster MUST get a distinct value here — reusing cluster_name across nodes makes every kubelet register under the same node name, silently clobbering each other. Null omits the hostname cloud-config directive entirely, letting cloud-init's own datasource assign its naturally-unique per-instance hostname instead (EC2/Azure both do this automatically) — required for ASG/VMSS-backed node pools, where Terraform applies one shared cloud-init payload to every instance the autoscaler creates and never sees individual instances to assign a static name to."
  type        = string
  default     = null
}

variable "k8s_version" {
  description = "K8s distro version to install (a K3s release string today, e.g. v1.36.1+k3s1). Neutral name so a future distro hop does not change the interface. Null uses the platform default (module.component_versions.k8s_version)."
  type        = string
  default     = null
}

variable "cilium_version" {
  description = "Cilium Helm chart version, only meaningful when cni = \"cilium\". Null uses the platform default (module.component_versions.cilium_version)."
  type        = string
  default     = null
}

variable "cluster_fqdn" {
  description = "Optional DNS name for the API/kubeconfig server and an extra TLS SAN. Null = use the node IP only. This is just a name string; how it resolves (managed DNS, a local resolver, or none) is the caller's concern."
  type        = string
  default     = null
}

variable "node_role" {
  description = "Bootstrap role this node renders cloud-init for: 'server-init' (first control-plane node — forms the etcd cluster), 'server-join' (an additional control-plane node), or 'worker' (joins as an agent only, no control plane). Only 'server-init' is fully rendered by this build; the other two are reserved for a later slice and fail fast at boot if selected."
  type        = string
  default     = "server-init"
  validation {
    condition     = contains(["server-init", "server-join", "worker"], var.node_role)
    error_message = "node_role must be one of: server-init, server-join, worker."
  }
}

variable "control_plane_taint" {
  description = "When true, the k3s server install adds --node-taint CriticalAddonsOnly=true:NoExecute so user workloads are excluded from this control-plane node. Only meaningful for node_role = server-init or server-join."
  type        = bool
  default     = false
}

variable "cluster_token" {
  description = "Shared secret used to join a server or agent to the cluster (k3s --token). Required when node_role is server-init, which forms the whole-cluster join secret. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "cluster_agent_token" {
  description = "Separate shared secret accepted only from agents (k3s --agent-token) — a worker presenting this value can join as an agent but never as a server/etcd member. Required when node_role is server-init. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "registration_address" {
  description = "IP or FQDN of the existing cluster's registration endpoint (a control plane's registration_address output). Used to build --server https://<address>:6443 for the k3s agent/server join. Required when node_role is server-join or worker; ignored for server-init."
  type        = string
  default     = null
}

variable "agent_token_fetch_command" {
  description = "Shell command that prints the k3s agent join token to stdout when run at boot (e.g. a cloud provider's CLI call to fetch a secret from its parameter/secrets store, assembled by a node-pool module). Keeps cloud-init provider-neutral: the caller decides how the token is fetched and delivered to the instance; cloud-init only executes the command it is given. Required when node_role is worker."
  type        = string
  default     = null
}

variable "node_labels" {
  description = "Extra --node-label flags applied at k3s install time, e.g. { \"topology.kubernetes.io/zone\" = \"eu-west-1a\" }. Provider-neutral: any caller may set arbitrary labels; cloud-init does not interpret the keys."
  type        = map(string)
  default     = {}
}

variable "extra_tls_sans" {
  description = "Additional --tls-san values for the k3s server cert (e.g. a registration endpoint's DNS name, or a wildcard hostname). Provider-neutral: any caller may supply arbitrary extra SANs. Only meaningful for node_role = server-init or server-join."
  type        = list(string)
  default     = []
}

variable "cni" {
  description = "CNI to install: 'flannel' (K3s built-in, default) or 'cilium'. Only meaningful for node_role server-init/server-join — a worker never renders CNI flags or manifests of its own. The caller (a control-plane module) resolves any topology-aware default; cloud-init always renders whichever value it is given."
  type        = string
  default     = "flannel"
  validation {
    condition     = contains(["flannel", "cilium"], var.cni)
    error_message = "cni must be 'flannel' or 'cilium'."
  }
}

variable "etcd_snapshot_enabled" {
  description = "Enable K3s' built-in scheduled etcd snapshots (local, with retention). Only meaningful for node_role server-init/server-join."
  type        = bool
  default     = false
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule for etcd snapshots (k3s --etcd-snapshot-schedule-cron). Only rendered when etcd_snapshot_enabled is true."
  type        = string
  default     = "0 */12 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Number of local etcd snapshots to retain before the oldest is pruned (k3s --etcd-snapshot-retention). Only rendered when etcd_snapshot_enabled is true."
  type        = number
  default     = 5
}

variable "etcd_snapshot_object_store_bucket" {
  description = "Optional object-store bucket name for uploading etcd snapshots off-node (S3-compatible API — k3s --etcd-s3-bucket). Null = local-only snapshots. Provider-neutral name: the caller (a control-plane module) resolves this to whatever object store its provider uses."
  type        = string
  default     = null
}

variable "etcd_snapshot_object_store_region" {
  description = "Region for the object-store bucket above (k3s --etcd-s3-region). Ignored when etcd_snapshot_object_store_bucket is null."
  type        = string
  default     = null
}

variable "etcd_snapshot_object_store_endpoint" {
  description = "Optional custom S3-compatible endpoint URL (k3s --etcd-s3-endpoint), for a non-default-AWS-S3 object store. Ignored when etcd_snapshot_object_store_bucket is null."
  type        = string
  default     = null
}

variable "etcd_snapshot_object_store_folder" {
  description = "Optional folder/prefix within the object-store bucket (k3s --etcd-s3-folder) — useful when multiple clusters share one bucket. Ignored when etcd_snapshot_object_store_bucket is null."
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

variable "argocd_version" {
  description = "Argo CD Helm chart version, only meaningful when gitops_platform_repo_url is set. Null uses the platform default (module.component_versions.argocd_version)."
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
  description = "Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. Use for optional platform features (secret store wiring, future extensions) without requiring cloud-init changes."
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

variable "extra_server_manifests" {
  description = "Arbitrary K3s auto-deploy manifest files (filename => full YAML content) written to /var/lib/rancher/k3s/server/manifests/ on server-init/server-join nodes only. cloud-init does not interpret the content — a control-plane module uses this to drop provider-specific server-side add-ons (e.g. a kube-vip DaemonSet on Proxmox) without cloud-init knowing what they are."
  type        = map(string)
  default     = {}
}
