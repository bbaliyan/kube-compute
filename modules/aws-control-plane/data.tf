# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No resource blocks belong in this file, ever.
# The module NEVER creates network fabric — it only reads a subnet (given or default-VPC).

data "aws_caller_identity" "current" {}

# Default-VPC fallback: only consulted when neither subnet_id nor subnet_name is provided.
data "aws_vpc" "default" {
  count   = (var.subnet_id == null && var.subnet_name == null) ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = (var.subnet_id == null && var.subnet_name == null) ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

# Named-VPC lookup — only consulted when subnet_name is provided with a vpc_name scope.
data "aws_vpc" "named" {
  count = (var.subnet_name != null && var.vpc_name != null) ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# Named-subnet lookup — resolves the ID from the Name tag.
# When vpc_name is also provided, a VPC filter narrows the search to avoid ambiguity.
data "aws_subnet" "by_name" {
  count = var.subnet_name != null ? 1 : 0

  filter {
    name   = "tag:Name"
    values = [var.subnet_name]
  }

  dynamic "filter" {
    for_each = local.named_vpc_id != null ? [local.named_vpc_id] : []
    iterator = vpc_id
    content {
      name   = "vpc-id"
      values = [vpc_id.value]
    }
  }
}

# Named hosted zone lookup — resolves the zone ID from the zone name.
data "aws_route53_zone" "private" {
  count        = var.hosted_zone_name != null ? 1 : 0
  name         = var.hosted_zone_name
  private_zone = true
}

# The subnet the node launches into. Also yields the VPC ID for the module-owned security group.
data "aws_subnet" "selected" {
  id = local.effective_subnet_id
}

# Authoritative arch lookup: AWS's own API returns supported_architectures for any instance type,
# past or future. This replaces pattern-matching on the instance type string.
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

# Latest AlmaLinux 10 for the derived arch — only when no explicit AMI is given.
# Owner 764336703387 is the AlmaLinux OS Foundation's AWS account (verified against the
# AlmaLinux bug tracker and AlmaLinux/cloud-images repo); architecture isn't embedded in
# the name (unlike AL2023's), so it's filtered separately below.
data "aws_ami" "almalinux10" {
  count       = var.os_image_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["764336703387"]
  filter {
    name   = "name"
    values = ["AlmaLinux OS 10*"]
  }
  filter {
    name   = "architecture"
    values = [local.ami_arch]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---- HA mode: derive the module's VPC from the genesis node's own subnet, not the single-node
# fallback (which is otherwise unused once control_plane_count > 1) ----
data "aws_subnet" "control_plane_genesis" {
  count = var.control_plane_count > 1 ? 1 : 0
  id    = local.genesis_subnet_id
}
