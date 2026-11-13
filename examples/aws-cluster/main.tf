# SPDX-License-Identifier: Apache-2.0
# A single-node cluster in an existing subnet. Every value is a placeholder.

terraform {
  required_version = ">= 1.12.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

module "cluster" {
  # From the registry: source = "bbaliyan/kube-compute/aws" and a version.
  source = "../../modules/aws-cluster"

  cluster_name          = "example"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-0123456789abcdef0"
  os_image_ami_id       = "ami-0123456789abcdef0"
}
