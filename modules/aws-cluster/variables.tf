# SPDX-License-Identifier: Apache-2.0
# Merged-directory composition of aws-control-plane + aws-node-pool, mirroring
# proxmox-cluster's shape and conventions — see this module's README for what
# proxmox-cluster carries that this module deliberately does NOT (node-os-patch,
# cluster-autoscaler) and why.

variable "cluster_name" {
  description = "Cluster identity. Used in tags, the FQDN, and the kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to the node OS trust store. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream."
  type        = string
  default     = null
}

variable "dns_servers" {
  description = "Upstream DNS resolver IPs for the control plane, passed through to node-bootstrap to give kubelet a search-domain-free resolv-conf — defense in depth against any node-inherited DNS search domain colliding with a wildcard cluster DNS record (*.<cluster>.<domain>, see cluster_domain), on top of node-bootstrap's own prefer_fqdn_over_hostname fix for the specific hostname-derived case. Null/empty (the default) leaves kubelet's default ClusterFirst DNS policy in place: every pod inherits its node's own /etc/resolv.conf search domain(s) verbatim. 169.254.169.253 (the VPC's own Amazon-provided DNS Resolver) is a safe default for a standard VPC. Each node_pools entry has its own dns_servers field for the same reason on workers — not auto-wired from this one, since a pool could reasonably live in a different VPC."
  type        = list(string)
  default     = null
}

variable "gitops_platform_enabled" {
  description = "Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application."
  type        = bool
  default     = true
}

variable "gitops_platform_repo_url_override" {
  description = "Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin."
  type        = string
  default     = null
}

variable "gitops_platform_revision_override" {
  description = "Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default."
  type        = string
  default     = null
}

variable "gitops_workloads_repo_url" {
  description = "Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application."
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

variable "cluster_type" {
  description = "Cluster topology intent: 'all_in_one' (control-plane nodes stay schedulable) or 'dedicated_control_plane' (control-plane nodes are tainted so user workloads run only on separate node pools)."
  type        = string
  default     = "all_in_one"
  validation {
    condition     = contains(["all_in_one", "dedicated_control_plane"], var.cluster_type)
    error_message = "cluster_type must be 'all_in_one' or 'dedicated_control_plane'."
  }
}

variable "cni" {
  description = "CNI to install: 'default' or 'cilium'. Null (default) resolves to 'cilium' regardless of topology — Canal/flannel's iptables/ipset dataplane ('default') is broken on AlmaLinux 10, this project's only supported OS (its kernel dropped modules flannel and Felix require). 'default' remains an escape hatch for a consumer-supplied playbook targeting a different OS."
  type        = string
  default     = null
  validation {
    condition     = var.cni == null || contains(["default", "cilium"], var.cni)
    error_message = "cni must be null, 'default', or 'cilium'."
  }
}

variable "cert_mode" {
  description = "Certificate issuer mode deployed by kube-platform. 'selfsigned' (default), 'byo', or 'acme'."
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

variable "workloads_extra_helm_parameters" {
  description = "Helm parameters forwarded verbatim to the workloads Application. See node-bootstrap for full description."
  type        = map(string)
  default     = {}
}

variable "platform_helm_values_object" {
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional tags applied to every AWS resource this module creates (EC2 instance, root EBS volume, security group, IAM role), and forwarded to node-bootstrap so platform-managed resources (e.g. CSI-provisioned storage) can tag themselves consistently."
  type        = map(string)
  default     = {}
}

# ---- AWS-specific inputs ----
variable "aws_region" {
  description = "AWS region the cluster runs in. Exposed as an output so the SSM control-plane scripts (and node pools) know which region to target. Does NOT configure the provider — the caller sets the provider region; pass the same value here."
  type        = string
}

variable "control_plane_count" {
  description = "Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain."
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 3, 5], var.control_plane_count)
    error_message = "control_plane_count must be 1, 3, or 5."
  }
}

variable "control_plane_subnets" {
  description = "Map of availability zone -> subnet id for control-plane placement, required when control_plane_count > 1. Ignored when control_plane_count = 1 — use subnet_id/subnet_name instead."
  type        = map(string)
  default     = null

  validation {
    condition     = var.control_plane_count == 1 || var.control_plane_subnets != null
    error_message = "control_plane_subnets is required when control_plane_count > 1."
  }
}

variable "endpoint_mode" {
  description = "How joining nodes reach the registration endpoint once control_plane_count > 1 (ignored for control_plane_count = 1): \"loadbalancer\" (default) creates an internal NLB; \"dns\" creates Route53 multivalue-answer A records; \"static\" uses static_registration_address verbatim."
  type        = string
  default     = "loadbalancer"
  validation {
    condition     = contains(["loadbalancer", "dns", "static"], var.endpoint_mode)
    error_message = "endpoint_mode must be one of: loadbalancer, dns, static."
  }
}

variable "static_registration_address" {
  description = "Consumer-supplied registration endpoint address, used verbatim as registration_address when endpoint_mode = \"static\". Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.endpoint_mode != "static" || var.static_registration_address != null
    error_message = "static_registration_address is required when endpoint_mode = \"static\"."
  }
}

# Networking: the module takes a network HANDLE and never creates fabric (VPC/subnet/IGW/NAT).
variable "subnet_id" {
  description = "Subnet the control-plane node (control_plane_count = 1) launches into. Null = the module falls back to a subnet in the account's default VPC."
  type        = string
  default     = null
}

variable "vpc_name" {
  description = "Name tag of the VPC. Pair with subnet_name to scope the subnet lookup to a specific VPC. Ignored when subnet_id is used."
  type        = string
  default     = null
}

variable "subnet_name" {
  description = "Name tag of the subnet to launch the control-plane node into (control_plane_count = 1 only). Alternative to subnet_id."
  type        = string
  default     = null
}

variable "cluster_domain" {
  description = "Optional DNS suffix for the cluster, e.g. 'example.internal'. When set, the FQDN is <cluster_name>.<cluster_domain> and the wildcard is *.<cluster_name>.<cluster_domain>. Null = node is reachable by IP only."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Name of the Route53 private hosted zone. Alternative to hosted_zone_id. Requires cluster_domain to be set."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID. Alternative to hosted_zone_name. Requires cluster_domain to be set. Null = create no record; register DNS yourself using the wildcard_dns_name output."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type (bundles vCPU + memory) for the control-plane node(s). CPU arch (arm64/x86_64) is derived from the family prefix for AMI selection."
  type        = string
  default     = "m7g.medium"
}

variable "os_image_ami_id" {
  description = "AMI ID for the control-plane node(s) — typically the output of kube-image's AWS Packer build. Tested with AlmaLinux 10 (RHEL-family — node-bootstrap uses dnf and update-ca-trust). Null = latest AlmaLinux 10 for the derived architecture via data lookup (a stock image with no RKE2 pre-baked — much slower first boot than a kube-image AMI, same tradeoff as Proxmox's proxmox_template_vm_id)."
  type        = string
  default     = null
}

variable "os_image_name" {
  description = "AMI name for the control-plane node(s), e.g. kube-image's self-descriptive build name. Alternative to os_image_ami_id — resolved to an ID via a data lookup scoped to this account and the derived architecture. Accepts EC2 Name-filter wildcards (*, ?): a pattern with the build date/suffix omitted resolves to the most recent matching build. Ignored when os_image_ami_id is set."
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports from outside the cluster — the networks you administer/reach the cluster from. Required — environment-specific."
  type        = list(string)
}

variable "ingress_ports" {
  description = "TCP ports opened on the control-plane security group: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH)."
  type        = list(number)
  default     = [80, 443, 6443]
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB) for the control-plane node(s). Covers OS + container image cache."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2, ...) for the control-plane node(s)."
  type        = string
  default     = "gp3"
}

# ---- Worker pools (optional, merged into this same directory/state) ----
variable "node_pools" {
  description = "Fixed-size worker pools (ASGs) joining this cluster, keyed by pool name (e.g. \"pool-a\"). Each pool is created via aws-node-pool, wired to this cluster's cluster_name/aws_region/registration_address/agent_token_ssm_parameter/cluster_security_group_id automatically — do not set those fields inside a pool object, they are ignored. Empty map (the default) creates no worker pools. Field names, types, and defaults mirror aws-node-pool's own variables.tf exactly (minus the auto-wired fields above)."
  type = map(object({
    trusted_ca_pem      = optional(string)
    registry_mirror_url = optional(string)
    dns_servers         = optional(list(string))
    subnet_id           = string
    desired_count       = optional(number, 2)
    instance_type       = optional(string, "m7g.medium")
    os_image_ami_id     = optional(string)
    os_image_name       = optional(string)
    root_volume_size_gb = optional(number, 20)
    root_volume_type    = optional(string, "gp3")
    extra_node_labels   = optional(map(string), {})
    extra_tags          = optional(map(string), {})
  }))
  default = {}
}
