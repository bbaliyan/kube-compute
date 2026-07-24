# SPDX-License-Identifier: Apache-2.0
# NOTE — scoped build (see README.md "Scope of this build"): this module
# currently wires only the variables needed for core RKE2 install/join
# mechanics, secrets flow, and per-provider connectivity. cloud-init's
# CA-trust/registry-mirror/GitOps-bootstrap/CNI-manifest/etcd-snapshot/
# node-label/extra-tag/extra-manifest variables are deliberately NOT ported
# yet — a follow-on ticket ports them and cuts the provider modules over from
# `cloud-init` to this module in one atomic step, to avoid a feature
# regression window on a working baseline.

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
  description = "CNI to install: 'default' (whatever this distro's template installs out of the box) or 'cilium'. Only sets the config.yaml cni:/disable-kube-proxy: flags in this scoped build — deploying the Cilium HelmChart manifest itself is deferred (see README). Only meaningful for node_role server-init/server-join."
  type        = string
  default     = "default"
  validation {
    condition     = contains(["default", "cilium"], var.cni)
    error_message = "cni must be 'default' or 'cilium'."
  }
}
