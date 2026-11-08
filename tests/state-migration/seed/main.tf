# SPDX-License-Identifier: Apache-2.0
# What a cluster finds in its account before the first apply: a named VPC and
# subnet, a private hosted zone, and a kube-images AMI for each architecture.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}

resource "aws_vpc" "example" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "example-vpc" }
}

resource "aws_subnet" "example" {
  for_each = { a = 1, b = 2, c = 3 }

  vpc_id            = aws_vpc.example.id
  cidr_block        = "10.0.${each.value}.0/24"
  availability_zone = "eu-west-1${each.key}"
  tags              = { Name = "example-subnet-${each.key}" }
}

resource "aws_route53_zone" "example" {
  name = "example.internal"

  vpc {
    vpc_id = aws_vpc.example.id
  }
}

resource "aws_ami" "kube_node" {
  for_each = toset(["x86_64", "arm64"])

  name                = "example-kube-node-${each.key}-20260101"
  architecture        = each.key
  root_device_name    = "/dev/xvda"
  virtualization_type = "hvm"
  ena_support         = true

  ebs_block_device {
    device_name = "/dev/xvda"
    volume_size = 8
  }
}

# The cases take these IDs as inputs instead of looking them up by name. Not
# every emulator stores an AMI's architecture or marks a zone as private, so
# the lookups by name would find nothing.
output "os_image_ami_id" {
  value = aws_ami.kube_node["x86_64"].id
}

output "hosted_zone_id" {
  value = aws_route53_zone.example.zone_id
}

output "subnet_a" {
  value = aws_subnet.example["a"].id
}

output "subnet_b" {
  value = aws_subnet.example["b"].id
}

output "subnet_c" {
  value = aws_subnet.example["c"].id
}
