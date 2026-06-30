# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No resource blocks belong in this file, ever.
# The module NEVER creates network fabric — it only reads a subnet (given or default-VPC).

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

# Latest Amazon Linux 2023 for the derived arch — only when no explicit AMI is given.
data "aws_ami" "al2023" {
  count       = var.os_image_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-${local.ami_arch}"]
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
