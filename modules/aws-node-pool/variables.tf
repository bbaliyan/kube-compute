# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to cloud-init) ----
variable "cloud_init_template" {
  description = "Absolute path to the cloud-init template to render. Defaults to the bundled AlmaLinux 9 template."
  type        = string
  default     = null
}

variable "cluster_name" {
  description = "Cluster identity this pool joins. Must match the control plane's cluster_name. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "k8s_version" {
  description = "K8s distro version this pool's workers install (a K3s release string, e.g. v1.36.1+k3s1). Must not be newer than control_plane_k8s_version — a kubelet may trail the API server by up to 3 minors, never lead it. Null uses the platform default (module.component_versions.k8s_version)."
  type        = string
  default     = null
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to the worker's OS trust store. Null = none. Sensitive."
  type        = string
  default     = null
  sensitive   = true
}

variable "registry_mirror_url" {
  description = "Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream."
  type        = string
  default     = null
}

# ---- AWS-specific inputs ----
variable "aws_region" {
  description = "AWS region the pool runs in. Must match the control plane's region."
  type        = string
}

variable "control_plane_k8s_version" {
  description = "The control plane's k8s_version. Pass the same value given to (or output by) the aws-control-plane module for this cluster; this pool's k8s_version is rejected if it is newer."
  type        = string
}

variable "registration_address" {
  description = "The control plane's registration_address output. Workers join via --server https://<this>:6443."
  type        = string
}

variable "agent_token_ssm_parameter" {
  description = "The control plane's agent_token_ssm_parameter output. This module's IAM role is scoped to read only this one SSM parameter."
  type        = string
}

variable "cluster_security_group_id" {
  description = "The control plane's cluster_security_group_id output. Attached to every worker instance for east-west cluster access; this module owns no other ingress security group in this slice (workers accept no traffic from outside the cluster yet)."
  type        = string
}

variable "subnet_id" {
  description = "Subnet the pool launches into. Pools are AZ-pinned by design: one pool = one subnet = one availability zone. The module never creates network fabric."
  type        = string
}

variable "desired_count" {
  description = "Fixed pool size. min_size = max_size = desired_capacity = this value — a fixed pool is the safe default for stateful workloads. Elastic (min<max + autoscaler) pools are a future, opt-in option, not this variable."
  type        = number
  default     = 2
  validation {
    condition     = var.desired_count >= 1
    error_message = "desired_count must be at least 1."
  }
}

variable "instance_type" {
  description = "EC2 instance type (bundles vCPU + memory) for every worker in this pool. CPU arch (arm64/x86_64) is derived from the family via AWS's own instance-type metadata."
  type        = string
  default     = "m7g.medium"
}

variable "os_image_ami_id" {
  description = "AMI ID for the workers. Tested with AlmaLinux 9 (RHEL-family — cloud-init uses dnf and update-ca-trust). Other RHEL-family images (Rocky, AL2023) may work but are untested — no compatibility guarantee. Null = latest AlmaLinux 9 for the derived architecture via data lookup."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB) for every worker."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2, ...)."
  type        = string
  default     = "gp3"
}

variable "extra_node_labels" {
  description = "Additional --node-label flags beyond the automatic AZ label (topology.kubernetes.io/zone) this module always sets from the pool's own subnet."
  type        = map(string)
  default     = {}
}

variable "extra_tags" {
  description = "Additional tags applied to every AWS resource this module creates (launch template, ASG instances, security group attachment, IAM role)."
  type        = map(string)
  default     = {}
}
