# SPDX-License-Identifier: Apache-2.0
# Join-token flow: generated here (not in aws-control-plane) so both aws-control-plane
# and aws-node-pool can depend on this one fast-applying unit instead of on each other.
# Two tokens, least privilege: the server token grants joining etcd/control-plane; the
# agent token is all a worker ever receives, so a compromised worker cannot rejoin as a
# control-plane/etcd member.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
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
  value = random_password.agent_token.result
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
