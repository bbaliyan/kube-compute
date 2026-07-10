# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to cloud-init) ----
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Defaults to the bundled AL2023 template. Supply your own path for other distributions — no compatibility guarantee is made for untested distributions."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Cluster identity. Used in tags, the FQDN, and the kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version (a K3s release string today, e.g. v1.36.1+k3s1). Neutral name. Null uses the platform default (module.component_versions.k8s_version)."
  type        = string
  default     = null
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

variable "gitops_platform_repo_url" {
  description = "Optional Argo CD platform Application source repo. Null = skip Argo CD wiring."
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
  description = "Path within the workloads repo the ApplicationSet scans."
  type        = string
  default     = "apps"
}

# ---- AWS-specific inputs ----
variable "aws_region" {
  description = "AWS region the node runs in. Exposed as an output so the SSM control-plane scripts know which region to target. Does NOT configure the provider — the caller sets the provider region; pass the same value here."
  type        = string
}

variable "cluster_type" {
  description = "Cluster topology intent: 'all_in_one' (control-plane nodes stay schedulable — every single-node cluster, and a small HA cluster doing double duty) or 'dedicated_control_plane' (control-plane nodes are tainted so user workloads run only on separate node pools). Taint cannot be derived from worker count because node pools are separate state this module cannot see."
  type        = string
  default     = "all_in_one"
  validation {
    condition     = contains(["all_in_one", "dedicated_control_plane"], var.cluster_type)
    error_message = "cluster_type must be 'all_in_one' or 'dedicated_control_plane'."
  }
}

variable "cni" {
  description = "CNI to install: 'flannel' or 'cilium'. Null (default) auto-derives to 'cilium' when control_plane_count > 1 (multi-node — NetworkPolicy, a kube-proxy-free dataplane, and Hubble justify the extra footprint) and 'flannel' for control_plane_count = 1 (K3s built-in, zero-config, smallest footprint). Set explicitly to override either default."
  type        = string
  default     = null
  validation {
    condition     = var.cni == null || contains(["flannel", "cilium"], var.cni)
    error_message = "cni must be null, 'flannel', or 'cilium'."
  }
}

variable "control_plane_count" {
  description = "Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain. 3 or 5 places one control-plane node per availability zone behind an internal NLB (see control_plane_subnets)."
  type        = number
  default     = 1
  validation {
    condition     = contains([1, 3, 5], var.control_plane_count)
    error_message = "control_plane_count must be 1, 3, or 5."
  }
}

variable "control_plane_subnets" {
  description = "Map of availability zone -> subnet id for control-plane placement, required when control_plane_count > 1 (one control-plane node per AZ, across at least 3 distinct AZs — the map's keys ARE those AZs, so the module needs no lookup to discover them). Ignored when control_plane_count = 1 — use subnet_id/subnet_name instead. The module never creates fabric; every value must be an existing subnet's id, already located in the AZ given by its key."
  type        = map(string)
  default     = null

  validation {
    condition     = var.control_plane_count == 1 || var.control_plane_subnets != null
    error_message = "control_plane_subnets is required when control_plane_count > 1 (the module does not auto-discover multi-AZ subnets for the HA control plane)."
  }
}

variable "endpoint_mode" {
  description = "How joining nodes reach the registration endpoint once control_plane_count > 1 (ignored for control_plane_count = 1, which has no endpoint at all): \"loadbalancer\" (default) creates an internal NLB; \"dns\" creates Route53 multivalue-answer A records with CloudWatch-alarm-backed health checks (cheaper, TTL-bound failover; requires cluster_domain plus a resolvable hosted zone); \"static\" creates neither and uses static_registration_address verbatim (bring your own load balancer/address)."
  type        = string
  default     = "loadbalancer"
  validation {
    condition     = contains(["loadbalancer", "dns", "static"], var.endpoint_mode)
    error_message = "endpoint_mode must be one of: loadbalancer, dns, static."
  }
}

variable "static_registration_address" {
  description = "Consumer-supplied registration endpoint address (e.g. your own load balancer's DNS name), used verbatim as registration_address when endpoint_mode = \"static\". Ignored otherwise. The module creates no load balancer or DNS record for this mode — you own that infrastructure."
  type        = string
  default     = null

  validation {
    condition     = var.endpoint_mode != "static" || var.static_registration_address != null
    error_message = "static_registration_address is required when endpoint_mode = \"static\"."
  }
}

variable "etcd_snapshots_enabled" {
  description = "Enable K3s' built-in scheduled etcd snapshots. Null (default) auto-derives to true when control_plane_count > 1 (HA — durability is default-on) and false for control_plane_count = 1 (optional, off by default). Set explicitly to override either default."
  type        = bool
  default     = null
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule for etcd snapshots, passed through to cloud-init. Only meaningful when etcd_snapshots_enabled resolves to true."
  type        = string
  default     = "0 */12 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Number of local etcd snapshots to retain, passed through to cloud-init. Only meaningful when etcd_snapshots_enabled resolves to true."
  type        = number
  default     = 5
}

variable "etcd_snapshot_s3_bucket" {
  description = "Optional S3 bucket name for uploading etcd snapshots off-node. Null = local-only snapshots. When set, the control-plane IAM role is granted a scoped S3 policy for exactly this bucket."
  type        = string
  default     = null
}

variable "etcd_snapshot_s3_region" {
  description = "Region for etcd_snapshot_s3_bucket. Null = defaults to aws_region when a bucket is given."
  type        = string
  default     = null
}

variable "etcd_snapshot_s3_endpoint" {
  description = "Optional custom S3-compatible endpoint URL, for a non-default-AWS-S3-region object store. Ignored when etcd_snapshot_s3_bucket is null."
  type        = string
  default     = null
}

variable "etcd_snapshot_s3_folder" {
  description = "Optional folder/prefix within etcd_snapshot_s3_bucket — useful when multiple clusters share one bucket. Ignored when etcd_snapshot_s3_bucket is null."
  type        = string
  default     = null
}

# Networking: the module takes a network HANDLE and never creates fabric (VPC/subnet/IGW/NAT).
variable "subnet_id" {
  description = <<-EOT
    Subnet to launch the node into. Pass it to plug in your own/corp networking. Null = the module
    falls back to a subnet in the account's DEFAULT VPC (a data lookup; the module never CREATES a
    VPC/subnet). Accounts whose default VPC was deleted must pass a subnet_id or subnet_name.
  EOT
  type        = string
  default     = null
}

variable "vpc_name" {
  description = "Name tag of the VPC. Pair with subnet_name to scope the subnet lookup to a specific VPC. Ignored when subnet_id is used."
  type        = string
  default     = null
}

variable "subnet_name" {
  description = "Name tag of the subnet to launch the node into. Alternative to subnet_id — the module resolves the ID via a data lookup. Pair with vpc_name when the name tag is not globally unique."
  type        = string
  default     = null
}

# DNS: optional convenience. The module never owns DNS as a hard dependency — if you don't pass a
# zone, it creates no record and you register the wildcard (see the wildcard_dns_name output) in
# whatever DNS you run (Route53, a local resolver, RFC2136, external-dns, sslip.io fallback...).
variable "cluster_domain" {
  description = "Optional DNS suffix for the cluster, e.g. 'example.internal'. When set, the FQDN is <cluster_name>.<cluster_domain> and the wildcard is *.<cluster_name>.<cluster_domain>. Null = node is reachable by IP only."
  type        = string
  default     = null
}

variable "hosted_zone_name" {
  description = "Name of the Route53 private hosted zone (e.g. \"example.internal\"). Alternative to hosted_zone_id — the module resolves the ID via a data lookup. Requires cluster_domain to be set."
  type        = string
  default     = null
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID. Alternative to hosted_zone_name — pass the literal ID. Requires cluster_domain to be set. Null = create no record; register DNS yourself using the wildcard_dns_name output."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type (bundles vCPU + memory). CPU arch (arm64/x86_64) is derived from the family prefix for AMI selection."
  type        = string
  default     = "m7g.medium"
}

variable "os_image_ami_id" {
  description = <<-EOT
    AMI ID for the node. MUST be a RHEL-family image (AL2023, Rocky, AlmaLinux) — cloud-init uses dnf and
    update-ca-trust. Null = latest Amazon Linux 2023 for the derived architecture via data lookup.
  EOT
  type        = string
  default     = null
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks allowed inbound to the cluster ports — the networks you administer/reach the cluster from. Required — environment-specific."
  type        = list(string)
}

variable "ingress_ports" {
  description = "TCP ports opened on the module SG: 443/80 Traefik, 6443 K3s API. Never add 22 (SSH)."
  type        = list(number)
  default     = [80, 443, 6443]
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB). Covers OS + container image cache."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2, ...)."
  type        = string
  default     = "gp3"
}

variable "cert_mode" {
  description = "Certificate issuer mode deployed by kube-platform. Passed through to the cloud-init platform Application parameters. 'selfsigned' (default), 'byo' (consumer provides byo-ca-tls Secret), 'acme' (ACME DNS-01)."
  type        = string
  default     = "selfsigned"
  validation {
    condition     = contains(["selfsigned", "byo", "acme"], var.cert_mode)
    error_message = "cert_mode must be 'selfsigned', 'byo', or 'acme'."
  }
}

variable "platform_extra_helm_parameters" {
  description = "Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. See cloud-init for full description."
  type        = map(string)
  default     = {}
}

variable "platform_helm_values_object" {
  description = "Arbitrary object forwarded to the platform Application as helm.valuesObject. Use for nested values that cannot be expressed as flat helm.parameters strings."
  type        = any
  default     = null
}

variable "extra_tags" {
  description = "Additional tags applied to every AWS resource this module creates (EC2 instance, root EBS volume, security group, IAM role), and forwarded to cloud-init so platform-managed resources (e.g. CSI-provisioned storage) can tag themselves consistently."
  type        = map(string)
  default     = {}
}
