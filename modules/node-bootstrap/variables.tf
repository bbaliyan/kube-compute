# SPDX-License-Identifier: Apache-2.0
# NOTE — scoped build (see README.md "Scope of this build"): this module
# still does not wire GitOps/Argo CD bootstrap (gitops_*, cert_mode,
# platform_*, extra_tags) — that's a distinct post-install step, ported
# separately. Nothing calls this module yet; the provider-module cutover
# (repointing from `cloud-init`, deleting it) is also still pending.

variable "ansible_playbook_path" {
  description = "Absolute path to the Ansible playbook to run. Use the bundled AlmaLinux 9 playbook (the default), or supply your own path for other distributions. No compatibility guarantee is made for untested distributions."
  type        = string
  default     = null
}

variable "ansible_connection_vars" {
  description = "Non-secret Ansible connection facts for this node, assembled by the caller (a provider module) since connection transport is inherently provider-specific — e.g. { ansible_connection = \"ssh\", ansible_host = \"10.0.1.5\", ansible_user = \"almalinux\", ansible_ssh_private_key_file = \"...\" } for Proxmox, or { ansible_connection = \"amazon.aws.aws_ssm\", ansible_aws_ssm_instance_id = \"i-...\", ansible_aws_ssm_region = \"...\", ansible_aws_ssm_bucket_name = \"...\" } for AWS. This module does not interpret the keys — it forwards them to ansible-playbook as extra-vars."
  type        = map(string)
}

variable "cluster_name" {
  description = "Cluster name. Drives the kubeconfig server SAN."
  type        = string
}

variable "node_name" {
  description = "Unique per-node name, also used as this node's Ansible inventory host pattern. RKE2/kubelet defaults the registered Kubernetes node name to the OS hostname, so every node in a multi-node cluster MUST get a distinct value here."
  type        = string
}

variable "k8s_version" {
  description = "K8s distro version to install (an RKE2 release string, e.g. v1.36.1+rke2r1). Neutral name so a future distro hop does not change the interface."
  type        = string
}

variable "cluster_fqdn" {
  description = "Optional DNS name for the API/kubeconfig server and an extra TLS SAN. Null = use the node IP only."
  type        = string
  default     = null
}

variable "node_role" {
  description = "Bootstrap role this node is being installed for: 'server-init' (first control-plane node — forms the etcd cluster), 'server-join' (an additional control-plane node), or 'worker' (joins as an agent only, no control plane)."
  type        = string
  validation {
    condition     = contains(["server-init", "server-join", "worker"], var.node_role)
    error_message = "node_role must be one of: server-init, server-join, worker."
  }
}

variable "control_plane_taint" {
  description = "When true, the rke2 server install adds a node-taint: CriticalAddonsOnly=true:NoExecute so user workloads are excluded from this control-plane node. Only meaningful for node_role = server-init or server-join."
  type        = bool
  default     = false
}

variable "cluster_token" {
  description = "Shared secret used to join a server to the cluster (rke2 config.yaml's token:). Required for node_role server-init and server-join alike — both receive the same freshly-generated cluster secret directly (there is no existing secret store to fetch a server token from). Sensitive: delivered to the Ansible run via the local-exec environment block, never as an extra-var or inventory value."
  type        = string
  default     = null
  sensitive   = true
}

variable "cluster_agent_token" {
  description = "Separate shared secret accepted only from agents (rke2 config.yaml's agent-token:) — a worker presenting this value can join as an agent but never as a server/etcd member. Only meaningful for node_role server-init (server-join callers omit it in every provider module checked). Sensitive: delivered via environment, never as an extra-var."
  type        = string
  default     = null
  sensitive   = true
}

variable "registration_address" {
  description = "IP or FQDN of the existing cluster's registration endpoint (a control plane's registration_address output). Used to build config.yaml's server: https://<address>:9345. Required for node_role server-join or worker; ignored for server-init."
  type        = string
  default     = null
}

variable "agent_token_fetch_command" {
  description = "Shell command that prints the rke2 agent join token to stdout when run on the node (e.g. a cloud provider's CLI call to fetch a secret from its parameter/secrets store). Required for node_role worker; ignored otherwise. Sensitive: some providers' fetch commands embed the raw token in the command string itself rather than genuinely fetching it out-of-band (e.g. Proxmox's node-pool module today passes a literal `echo '<token>'`), so this is treated as sensitive uniformly and delivered via environment, never as an extra-var."
  type        = string
  default     = null
  sensitive   = true
}

variable "extra_tls_sans" {
  description = "Additional tls-san: entries for the rke2 server cert. Only meaningful for node_role = server-init or server-join."
  type        = list(string)
  default     = []
}

variable "cni" {
  description = "CNI to install: 'default' (whatever this distro's template installs out of the box) or 'cilium'. Sets the config.yaml cni:/disable-kube-proxy: flags and, when 'cilium', deploys the Cilium HelmChart manifest (server-init/server-join only)."
  type        = string
  default     = "default"
  validation {
    condition     = contains(["default", "cilium"], var.cni)
    error_message = "cni must be 'default' or 'cilium'."
  }
}

variable "cilium_version" {
  description = "Cilium Helm chart version. Only meaningful when cni = \"cilium\"."
  type        = string
  default     = null
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) to add to the OS trust store via update-ca-trust, and to pin containerd's TLS verification of a registry_mirror_url host. Effect, not use case: a private/corp/homelab CA, or null to skip. Sensitive: delivered to the Ansible run via the local-exec environment block, never as an extra-var — the same treatment as the join-secret variables above."
  type        = string
  default     = null
  sensitive   = true
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream registries directly."
  type        = string
  default     = null
}

variable "etcd_snapshot_enabled" {
  description = "Enable RKE2's built-in scheduled etcd snapshots (local, with retention). Only meaningful for node_role server-init/server-join."
  type        = bool
  default     = false
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule for etcd snapshots (rke2 config.yaml's etcd-snapshot-schedule-cron:). Only rendered when etcd_snapshot_enabled is true."
  type        = string
  default     = "0 */12 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Number of local etcd snapshots to retain before the oldest is pruned (rke2 config.yaml's etcd-snapshot-retention:). Only rendered when etcd_snapshot_enabled is true."
  type        = number
  default     = 5
}

variable "etcd_snapshot_object_store_bucket" {
  description = "Optional object-store bucket name for uploading etcd snapshots off-node (S3-compatible API — rke2 config.yaml's etcd-s3-bucket:). Null = local-only snapshots."
  type        = string
  default     = null
}

variable "etcd_snapshot_object_store_region" {
  description = "Region for the object-store bucket above (rke2 config.yaml's etcd-s3-region:). Ignored when etcd_snapshot_object_store_bucket is null."
  type        = string
  default     = null
}

variable "etcd_snapshot_object_store_endpoint" {
  description = "Optional custom S3-compatible endpoint URL (rke2 config.yaml's etcd-s3-endpoint:), for a non-default-AWS-S3 object store. Ignored when etcd_snapshot_object_store_bucket is null."
  type        = string
  default     = null
}

variable "etcd_snapshot_object_store_folder" {
  description = "Optional folder/prefix within the object-store bucket (rke2 config.yaml's etcd-s3-folder:) — useful when multiple clusters share one bucket. Ignored when etcd_snapshot_object_store_bucket is null."
  type        = string
  default     = null
}

variable "node_labels" {
  description = "Extra node-label: entries applied at rke2 install time, e.g. { \"topology.kubernetes.io/zone\" = \"eu-west-1a\" }. Only meaningful for node_role = worker."
  type        = map(string)
  default     = {}
}

variable "extra_server_manifests" {
  description = "Arbitrary RKE2 auto-deploy manifest files (filename => full YAML content) written to /var/lib/rancher/rke2/server/manifests/ on server-init/server-join nodes only. This module does not interpret the content."
  type        = map(string)
  default     = {}
}
