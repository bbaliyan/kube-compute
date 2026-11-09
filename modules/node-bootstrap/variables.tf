# SPDX-License-Identifier: Apache-2.0
variable "cluster_name" {
  description = "Cluster name. It sets the clusterName Helm parameter, the iSCSI initiator name and CLUSTER_NAME in node.env."
  type        = string
}

variable "node_name" {
  description = "Unique per-node name, set as this node's cloud-init hostname (and fqdn, when cluster_fqdn_suffix is set). RKE2/kubelet defaults the registered Kubernetes node name to the OS hostname, so every node in a multi-node cluster MUST get a distinct value here."
  type        = string
}

variable "cluster_fqdn" {
  description = "Optional DNS name for the API/kubeconfig server and an extra TLS SAN. Null = use the node IP only."
  type        = string
  default     = null
}

variable "cluster_fqdn_suffix" {
  description = "Optional DNS suffix under which the platform's web-UI ingress hostnames are published (e.g. 'my-cluster.example.com' yields argocd.my-cluster.example.com). Distinct from cluster_fqdn, which is the API server name (api.<suffix>) — the ingress suffix must not carry the 'api.' prefix. Null/empty disables platform ingress."
  type        = string
  default     = null
}

variable "node_fqdn_label" {
  description = "Optional override for the fqdn's leftmost label (before cluster_fqdn_suffix), when it should differ from node_name. node_name is also this node's OS hostname and (on Proxmox) its VM/tag name in the provider UI, where a cluster-name prefix is useful for telling clusters apart at a glance; the fqdn already carries that identity in its suffix (cluster_fqdn_suffix embeds cluster_name), so repeating the prefix there is redundant. Null (the default) uses node_name for the label, preserving existing behavior."
  type        = string
  default     = null
}

variable "set_hostname" {
  description = "Whether cloud-init sets hostname and fqdn from node_name. true (the default) is required for a node with its own render, because RKE2 registers the node by OS hostname. false omits both keys, for a render shared by several VMs such as an Auto Scaling group. The platform metadata then supplies the hostname."
  type        = bool
  default     = true
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
  description = "Shared secret used to join a server to the cluster (rke2 config.yaml's token:). Required for node_role server-init and server-join alike — both receive the same freshly-generated cluster secret directly (no existing secret store to fetch a server token from). Sensitive: written into the 0600 /etc/rancher/rke2/config.yaml of the cloud-init payload."
  type        = string
  default     = null
  sensitive   = true
}

variable "cluster_agent_token" {
  description = "Separate shared secret accepted only from agents (rke2 config.yaml's agent-token:) — a worker presenting this value can join as an agent but never as a server/etcd member. Only meaningful for node_role server-init (server-join callers omit it in every provider module checked). Sensitive: written into the 0600 /etc/rancher/rke2/config.yaml of the cloud-init payload."
  type        = string
  default     = null
  sensitive   = true
}

variable "registration_address" {
  description = "IP or FQDN of the existing cluster's registration endpoint (a control plane's registration_address output). Used to build config.yaml's server: https://<address>:9345. Required for node_role server-join or worker. Optional for server-init: when set, the node probes this address at boot and joins the cluster that answers instead of initializing a new one (the rejoin probe)."
  type        = string
  default     = null
}

variable "rejoin_probe_addresses" {
  description = "IPs or FQDNs a server-init node probes, in order, before it starts etcd. The node joins the cluster of the first address that answers and initializes a new cluster only if none does. Use it when registration_address points back at the node itself. Empty (the default) means the node probes registration_address, if set. Only meaningful for node_role = server-init."
  type        = list(string)
  default     = []
}

variable "agent_token_fetch_command" {
  description = "Shell command that prints the rke2 agent join token to stdout when run on the node (e.g. a cloud provider's CLI call to fetch a secret from its parameter/secrets store). Required for node_role worker; ignored otherwise. Sensitive: some providers' fetch commands embed the raw token in the command string itself rather than fetching it out-of-band (e.g. Proxmox's node-pool module passes a literal `echo '<token>'`), so this is treated as sensitive uniformly and written into the cloud-init payload's 0600 /opt/kube-compute/secrets.env."
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
  description = "CNI to install: 'cilium' (the default) or 'default' (the CNI the image ships, Canal). 'default' is not viable on AlmaLinux 10, whose kernel lacks the modules Canal needs. 'cilium' sets disable: [rke2-cilium] on a genesis node so the Cilium manifest from the platform ref is the only Cilium install. It needs the platform repo (gitops_platform_repo_url) on the genesis node."
  type        = string
  default     = "cilium"
  validation {
    condition     = contains(["default", "cilium"], var.cni)
    error_message = "cni must be 'default' or 'cilium'."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) to add to the OS trust store via update-ca-trust, and to pin containerd's TLS verification of a registry_mirror_url host. Effect, not use case: a private CA, or null to skip. Sensitive: written directly into the cloud-init payload as the anchors file, base64-encoded."
  type        = string
  default     = null
  sensitive   = true
}

variable "trusted_ca_in_image" {
  description = "Whether the node image already carries trusted_ca_pem at /etc/pki/ca-trust/source/anchors/trusted-ca.crt. true keeps the PEM out of user data while still using its value for containerd's TLS pin and the platform Application's trustedCaPemB64 parameter. The bootstrap program fails the boot if the image does not carry the file."
  type        = bool
  default     = false
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream registries directly."
  type        = string
  default     = null
}

variable "node_labels" {
  description = "Extra node-label: entries applied at rke2 install time, e.g. { \"topology.kubernetes.io/zone\" = \"eu-west-1a\" }. Only meaningful for node_role = worker."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "Extra node-taint: entries applied at rke2 install time, each a full \"key=value:Effect\" string (e.g. [\"dedicated=true:NoSchedule\"]). Only meaningful for node_role = worker: the server roles fill the same single config.yaml key from control_plane_taint. A label and a nodeSelector make a node merely preferred; only a taint keeps other pods off it."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.node_taints : can(regex("^[^=:]+=[^=:]*:(NoSchedule|PreferNoSchedule|NoExecute)$", t))])
    error_message = "each node_taints entry must be key=value:Effect, where Effect is NoSchedule, PreferNoSchedule, or NoExecute."
  }
}

variable "extra_server_manifests" {
  description = "Arbitrary RKE2 auto-deploy manifest files (filename => full YAML content) written to /var/lib/rancher/rke2/server/manifests/ on server-init/server-join nodes only. This module does not interpret the content."
  type        = map(string)
  default     = {}
}

variable "gitops_platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. false = skip Argo CD and the platform Application entirely (a bare RKE2+Cilium cluster) regardless of gitops_platform_repo_url/_revision. Only meaningful for node_role = server-init."
  type        = bool
  default     = true
}

variable "gitops_platform_repo_url" {
  description = "Argo CD platform Application source repo (kube-platform or a fork). Null/\"\" (the default) falls back to local.pinned_platform_repo_url — see that local for why the pin lives there rather than as this variable's default. The genesis node also clones it for bootstrap/rendered/cilium.yaml and argocd.yaml. When gitops_platform_enabled is false, there is no fallback to the pin and this input is required if the node needs Cilium or Argo CD. Only meaningful for node_role = server-init."
  type        = string
  default     = null
}

variable "gitops_platform_revision" {
  description = "Branch/tag/SHA the platform Application tracks. The genesis node clones the same ref for its boot manifests (a 40-digit hex value is checked out as a commit). Null/\"\" (the default) falls back to local.pinned_platform_revision — kube-platform's protected `main` branch, not a fixed commit — see that local for why. Override for a fork or to pin a specific revision instead."
  type        = string
  default     = null
}

variable "gitops_workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, fully independent of the platform Application — no shared app-of-apps parent, no enforced ordering (Argo CD's own automated selfHeal/retry converges a workload that depends on something platform provides, once platform catches up). Null/empty (the default) = no workloads Application at all. Only meaningful for node_role = server-init."
  type        = string
  default     = null
}

variable "gitops_workloads_revision" {
  description = "Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops_workloads_repo_url is set."
  type        = string
  default     = "main"
}

variable "gitops_workloads_path" {
  description = "Path within the workloads repo Argo CD applies. Only meaningful when gitops_workloads_repo_url is set."
  type        = string
  default     = "."
}

variable "workloads_extra_helm_parameters" {
  description = "Additional Helm parameters forwarded verbatim to the workloads Application. Only meaningful when gitops_workloads_repo_url is set."
  type        = map(string)
  default     = {}
}

variable "workloads_helm_values_object" {
  # any and the try() fallback in locals, for the same reasons as
  # platform_helm_values_object below.
  description = "Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations."
  type        = any
  default     = null
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
  description = "Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application."
  type        = map(string)
  default     = {}
}

variable "platform_helm_values_object" {
  # any, not map(any): map(any) forces every top-level value to unify to one
  # common type, which breaks the moment two callers' objects have
  # genuinely different-shaped attributes (e.g. a list value next to
  # a nested object) -- "all map
  # elements must have the same type". Stays `any`; the null-fallback in
  # locals.platform_values_object uses try(), not a `? :` ternary or
  # coalesce(), specifically because try() is the one HCL construct whose
  # own arguments are exempt from static type-consistency checking.
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject. Use for nested values that cannot be expressed as flat helm.parameters strings."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional tags forwarded to the platform bootstrap Application (as part of helm.valuesObject.extraTags) so Kubernetes-managed resources can tag themselves consistently with the node's own tags."
  type        = map(string)
  default     = {}
}

variable "dns_servers" {
  description = "Resolver IPs for kubelet and pods, for example the list your VM network config uses. Null or empty (the default) leaves kubelet on the node's own /etc/resolv.conf. A list writes a kubelet resolv.conf with no search domain. See the README, section \"DNS search domains\"."
  type        = list(string)
  default     = null
}

variable "genesis_apply_manifests" {
  description = "Ordered list of {path, content} manifests to write under /opt/kube-compute/manifests/ and apply via bootstrap.sh, (this module does not interpret content). Empty list (default) applies nothing beyond the existing platform/workloads Applications. Only meaningful for node_role = server-init — genesis-only, mirroring render_cilium/render_argocd."
  type = list(object({
    path    = string
    content = string
  }))
  default = []

  validation {
    condition     = alltrue([for m in var.genesis_apply_manifests : !can(regex("[[:space:]]", m.path))])
    error_message = "genesis_apply_manifests: a path must not contain whitespace. bootstrap.sh word-splits the list of paths."
  }

  validation {
    condition     = alltrue([for m in var.genesis_apply_manifests : startswith(m.path, "/opt/kube-compute/manifests/") && length(m.path) > length("/opt/kube-compute/manifests/")])
    error_message = "genesis_apply_manifests: a path must be absolute and name a file under /opt/kube-compute/manifests/."
  }

  validation {
    condition     = alltrue([for m in var.genesis_apply_manifests : !contains(split("/", m.path), "..")])
    error_message = "genesis_apply_manifests: a path must not contain a .. segment."
  }
}

variable "graceful_shutdown" {
  description = "How long kubelet holds up an OS shutdown to evict pods, so a node that is stopped on a schedule -- or terminated by an autoscaler -- stops its workloads instead of having them killed with it. critical_seconds is the part of that reserved for critical pods, and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables the feature, leaving pods to be killed when containerd goes down. Keep the total well under the two minutes a cloud gives an instance before it pulls the power."
  type = object({
    seconds          = optional(number, 90)
    critical_seconds = optional(number, 30)
  })
  default = {}

  validation {
    condition     = var.graceful_shutdown == null ? true : var.graceful_shutdown.seconds > var.graceful_shutdown.critical_seconds
    error_message = "graceful_shutdown.seconds must exceed critical_seconds: critical pods are evicted inside the same window, not after it."
  }

  validation {
    condition     = var.graceful_shutdown == null ? true : var.graceful_shutdown.critical_seconds > 0
    error_message = "graceful_shutdown.critical_seconds must be greater than zero."
  }
}

variable "os_auto_updates" {
  description = "Installs OS updates daily with dnf-automatic, without rebooting, once the node has joined. RKE2's own packages are excluded from dnf, since system-upgrade-controller upgrades them. Also installs yum-utils, whose needs-restarting reports when a reboot is due. False leaves the node's packages as baked."
  type        = bool
  default     = true
}

variable "boot_scripts" {
  description = "Bash scripts run at the node's first boot, in order, before RKE2 is installed. Each sees CLUSTER_NAME, NODE_ROLE (control-plane or worker) and NODE_NAME in its environment. They travel as MIME shell-script parts of user_data. Empty (the default) runs none."
  type        = list(string)
  default     = []
}

variable "provider_steps" {
  description = "Boot steps that belong to one provider. The provider module builds them, so this module holds no provider logic. Each step has a name and cloud-init runcmd commands (a command is a list of strings). They run in order, before the module's own commands and the boot program. The names appear in the boot_steps output."
  type = list(object({
    name     = string
    commands = list(list(string))
  }))
  default = []

  validation {
    condition     = length(distinct([for step in var.provider_steps : step.name])) == length(var.provider_steps)
    error_message = "provider_steps: every step name must be unique."
  }
}

variable "provider_files" {
  description = "Files that the provider steps need, written by cloud-init before any command runs. Sensitive content is allowed."
  type = list(object({
    path        = string
    content     = string
    permissions = optional(string, "0644")
  }))
  default = []
}
