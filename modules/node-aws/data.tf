# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No resource blocks belong in this file, ever.
# The module NEVER creates network fabric — it only reads a subnet (given or default-VPC).

# Default-VPC fallback: only consulted when no subnet_id is provided.
data "aws_vpc" "default" {
  count   = var.subnet_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
}

# The subnet the node launches into (the given subnet_id, or the first default-VPC subnet).
# Also yields the VPC ID for the module-owned security group.
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
