# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to node-bootstrap) ----
variable "cluster_name" {
  description = "Cluster identity. Used in tags, the FQDN, and the kubeconfig SAN. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version (a K3s release string today, e.g. v1.32.5+k3s1). Neutral name."
  type        = string
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

# Networking: the module takes a network HANDLE and never creates fabric (VPC/subnet/IGW/NAT).
variable "subnet_id" {
  description = <<-EOT
    Subnet to launch the node into. Pass it to plug in your own/corp networking. Null = the module
    falls back to a subnet in the account's DEFAULT VPC (a data lookup; the module never CREATES a
    VPC/subnet). Accounts whose default VPC was deleted must pass a subnet_id.
  EOT
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

variable "hosted_zone_id" {
  description = "Optional Route53 hosted zone ID. When set (and cluster_domain is set), the module creates the wildcard A record in that zone. Null = create no record; register DNS yourself using the wildcard_dns_name output."
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
