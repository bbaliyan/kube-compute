# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No fabric-creating resource belongs in this file, ever.

# The subnet every node in the group launches into. Also yields the AZ (for the
# node label) and the VPC ID.
data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_caller_identity" "current" {}

# Authoritative arch lookup, same approach as aws-control-plane and
# aws-node-pool: AWS's own API reports supported_architectures for any instance
# type, past or future, so no per-family lookup table has to be maintained here.
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

# Self-owned AMI resolved by name (kube-image's own naming convention) -- only
# when an explicit ID isn't given but a name/pattern is. Scoped to this account
# (owners = ["self"]) and to the derived architecture, which is what lets one
# os_image_name value with a wildcard architecture segment serve an arm64
# platform node and an x86_64 dedicated-workload node in the same cluster without the
# two builds colliding.
data "aws_ami" "by_name" {
  count       = (var.os_image_ami_id == null && var.os_image_name != null) ? 1 : 0
  most_recent = true
  owners      = ["self"]
  filter {
    name   = "name"
    values = [var.os_image_name]
  }
  filter {
    name   = "architecture"
    values = [local.ami_arch]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

# Latest AlmaLinux 10 for the derived arch -- only when neither an explicit ID
# nor a name is given. Owner 764336703387 is the AlmaLinux OS Foundation's own
# AWS account; architecture isn't embedded in the name, so it is filtered
# separately.
data "aws_ami" "almalinux10" {
  count       = (var.os_image_ami_id == null && var.os_image_name == null) ? 1 : 0
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
