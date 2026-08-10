# SPDX-License-Identifier: Apache-2.0
module "cluster_facts" {
  source = "../cluster-facts"

  platform_enabled           = var.platform_enabled
  platform_repo_url_override = var.platform_repo_url_override
  platform_revision_override = var.platform_revision_override
  workloads_repo_url         = var.workloads_repo_url
  workloads_revision         = var.workloads_revision
  workloads_path             = var.workloads_path
}

locals {
  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })

  effective_vpc_id = var.vpc_id != null ? var.vpc_id : one(data.aws_vpc.named[*].id)
}

# ---- Delivery: the agent token is mirrored into an SSM SecureString and fetched at
# boot via the worker's own instance IAM role — never rendered into user_data. Moved
# here (out of aws-control-plane) because aws-node-pool only ever needs this
# parameter's plan-known NAME, but keeping the resource itself alongside the security
# group below means aws-cluster-facts is the one place holding everything node-pool
# needs early, rather than splitting by "must move" vs "happens to also live here".
resource "aws_ssm_parameter" "agent_token" {
  name  = "/kube-compute/${var.cluster_name}/agent-token"
  type  = "SecureString"
  value = module.cluster_facts.agent_token
  tags  = local.common_tags
}

# ---- Cluster security group: self-referencing, every cluster member (east-west) ----
# Moved here (out of aws-control-plane) because aws-node-pool's workers attach to this
# by real ID (vpc_security_group_ids), a hard AWS API dependency — an EC2 instance
# cannot reference a security-group ID that doesn't exist yet, unlike Proxmox's
# name-based/existence-tolerant ipsets. All-protocol among members rather than pinning
# to today's CNI ports: this SG is meant to outlive a CNI switch without an edit.
resource "aws_security_group" "cluster" {
  name_prefix = "kube-compute-${var.cluster_name}-cluster-"
  description = "kube-compute ${var.cluster_name}: east-west traffic among cluster members only."
  vpc_id      = local.effective_vpc_id
  tags        = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "all traffic among cluster members"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.cluster.id
  tags                         = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster-self" })
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster-egress-all" })
}
