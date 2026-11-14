# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      domain_name = "d111111abcdef8.cloudfront.net"
      arn         = "arn:aws:cloudfront::mock-account:distribution/EDFDVBD6EXAMPLE"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::kube-compute-oidc-example" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures = ["x86_64"]
      default_vcpus           = 2
      memory_size             = 8192
    }
  }
}

variables {
  os_image_name         = "kube-image-*"
  cluster_name          = "example"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "pod_identity_is_off_by_default" {
  command = plan

  assert {
    condition     = length(module.pod_identity) == 0
    error_message = "pod identity must create nothing unless pod_identity_enabled is true"
  }
  assert {
    condition     = output.pod_identity_issuer_url == null && output.pod_identity_role_arns == null && output.pod_identity_keys_put_policy_json == null
    error_message = "the pod identity outputs must be null when it is off"
  }
}

run "pod_identity_can_be_turned_on" {
  command = plan

  variables {
    pod_identity_enabled = true
  }

  assert {
    condition     = length(module.pod_identity) == 1
    error_message = "pod_identity_enabled must create the module"
  }
  assert {
    condition     = output.pod_identity_issuer_url == "https://d111111abcdef8.cloudfront.net"
    error_message = "the issuer URL must reach the output"
  }
}
