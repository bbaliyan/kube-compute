# SPDX-License-Identifier: Apache-2.0

# ---- Common inputs (pass through to node-bootstrap) ----
variable "cluster_name" {
  description = "Cluster identity these nodes join. Must match the control plane's cluster_name. Lowercase, starts with a letter."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, start with a letter, max 31 chars."
  }
}

variable "group_name" {
  description = "Short name for this group of nodes, used in every instance name and Kubernetes node name (<cluster_name>-<group_name>-<n>) and in the names of the IAM role and instance profile. Names a ROLE, not a machine: \"platform\", \"dedicated\", \"build\". Lowercase alphanumeric/hyphens."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}$", var.group_name))
    error_message = "group_name must be lowercase alphanumeric/hyphens, start with a letter, max 21 chars."
  }
}

variable "trusted_ca_pem" {
  description = "Optional PEM cert(s) added to each node's OS trust store. Null = none. Sensitive."
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
  description = "Upstream DNS resolver IPs, passed through to node-bootstrap to give kubelet a search-domain-free resolv-conf. Pass the same value the control plane got: a wildcard cluster DNS record poisons every node's pods identically, not just the control plane's."
  type        = list(string)
  default     = null
}

variable "cluster_fqdn_suffix" {
  description = "The control plane's fqdn_suffix (e.g. cluster-1.eu-west-1.example.net), used only to give each node a matching cloud-init fqdn so hostnames read consistently across the cluster. Null skips the fqdn, leaving the short hostname. Never the API server name -- that is the control plane's own cluster_fqdn."
  type        = string
  default     = null
}

# ---- AWS-specific inputs ----
variable "aws_region" {
  description = "AWS region these nodes run in. Must match the control plane's region."
  type        = string
}

variable "registration_address" {
  description = "The control plane's registration_address output. Nodes join via config.yaml's server: https://<this>:9345 (RKE2's supervisor/join port, distinct from the 6443 API port)."
  type        = string
}

variable "agent_token_ssm_parameter" {
  description = "This cluster's aws-control-plane agent_token_ssm_parameter output. This module's IAM role is scoped to read only this one SSM parameter."
  type        = string
}

variable "security_group_ids" {
  description = "Security groups attached to every node in this group. Pass the control plane's cluster_security_group_id at minimum. Add its node_security_group_id for a group that runs the ingress controller -- external traffic on ingress_ports reaches whichever node the ingress pods sit on, so moving them off the control plane without moving this rule means the ports answer nowhere."
  type        = list(string)
  validation {
    condition     = length(var.security_group_ids) > 0
    error_message = "security_group_ids must contain at least the cluster security group -- a node with no group cannot reach the control plane to join."
  }
}

variable "subnet_id" {
  description = "Subnet every node in this group launches into. Pass the control plane's own subnet_id output unless there is a deliberate reason not to: that keeps the whole cluster in one availability zone, which EBS requires (a volume cannot cross zones) and which avoids paying for cross-zone traffic in both directions. AZ pinning is a consequence of that, not a latency decision -- cross-zone latency inside a region is low single-digit milliseconds. This module never creates network fabric."
  type        = string
}

variable "node_count" {
  description = "How many named instances this group has. Each one is a separately-tracked aws_instance with its own stable id, its own Kubernetes node name, and its own cloud-init render -- unlike an autoscaling group, where Terraform never sees individual members. That is the whole reason this module exists; see README.md."
  type        = number
  default     = 1
  validation {
    condition     = var.node_count >= 1 && var.node_count <= 20
    error_message = "node_count must be between 1 and 20. Past that, the per-instance model this module exists for stops paying for itself -- use an autoscaled path instead."
  }
}

variable "instance_type" {
  description = "EC2 instance type for every node in this group. CPU architecture (arm64/x86_64) is derived from the family via AWS's own instance-type metadata, so an arm64 type resolves an arm64 image with no second input."
  type        = string
  default     = "m7g.medium"
}

variable "os_image_ami_id" {
  description = "AMI ID for these nodes. Tested with AlmaLinux 10 (RHEL-family -- cloud-init uses dnf and update-ca-trust). Null = latest AlmaLinux 10 for the derived architecture via data lookup."
  type        = string
  default     = null
}

variable "os_image_name" {
  description = "AMI name for these nodes, e.g. kube-image's self-descriptive build name. Alternative to os_image_ami_id -- the module resolves the ID scoped to this account's own AMIs and the derived architecture. Accepts EC2 Name-filter wildcards (*, ?), so a pattern whose architecture segment is a wildcard resolves correctly for both architectures in the same cluster. Ignored when os_image_ami_id is set."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size (GB) for every node in this group."
  type        = number
  default     = 20
}

variable "root_volume_type" {
  description = "Root EBS volume type (gp3, gp2, io2, ...)."
  type        = string
  default     = "gp3"
}

variable "node_labels" {
  description = "Additional node-label: entries beyond the automatic AZ label (topology.kubernetes.io/zone) this module always sets from the subnet, and the automatic kube-compute.io/node-group label it sets from group_name. Labels are what a workload SELECTS a node by; on their own they keep nothing else off it -- that is node_taints' job."
  type        = map(string)
  default     = {}
}

variable "node_taints" {
  description = "node-taint: entries applied at rke2 install time, each a full \"key=value:Effect\" string (e.g. [\"dedicated=true:NoSchedule\"]). Empty (the default) leaves the group open to any pod. Set it together with a matching toleration on the workload that belongs here, or nothing schedules at all."
  type        = list(string)
  default     = []
}

variable "attach_ebs_csi_policy" {
  description = "Whether to attach AWS's managed AmazonEBSCSIDriverPolicy to this group's IAM role. True by default and deliberately so: the EBS CSI CONTROLLER makes the CreateVolume/AttachVolume calls and is an ordinary Deployment the scheduler can place on any node that tolerates its taints, so a group without the policy silently breaks volume provisioning whenever the controller lands there. Set false only for a group you have kept the controller off by taint."
  type        = bool
  default     = true
}

variable "extra_tags" {
  description = "Additional tags applied to every AWS resource this module creates (instances, root volumes, IAM role, instance profile)."
  type        = map(string)
  default     = {}
}
