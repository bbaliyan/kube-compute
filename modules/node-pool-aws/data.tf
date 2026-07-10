# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No fabric-creating resource belongs in this file, ever.

# The subnet the pool launches into. Also yields the AZ (for the node label) and VPC ID.
data "aws_subnet" "selected" {
  id = var.subnet_id
}

data "aws_caller_identity" "current" {}

# Authoritative arch lookup, same approach as control-plane-aws: AWS's own API reports
# supported_architectures for any instance type, past or future.
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
