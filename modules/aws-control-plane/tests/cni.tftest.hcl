# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/cp-lb-mock/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/cp-tg-mock/1234567890123456" }
  }
}

variables {
  argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256 = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
  os_image_ami_id        = "ami-0123456789abcdef0"
  cluster_name           = "example"
  aws_region             = "eu-west-1"
  instance_type          = "m7g.large"
  allowed_ingress_cidrs  = ["10.0.0.0/8"]
  subnet_id              = "subnet-abc"
}

# NOTE: this module hands `cni` to `node-bootstrap`, which renders it into a
# base64 `write_files` entry. No test here asserts on the rendered result.

run "invalid_cni_rejected" {
  command = plan
  variables {
    cni = "calico"
  }
  expect_failures = [var.cni]
}

run "cluster_sg_self_reference_covers_any_cni" {
  command = plan
  # aws-control-plane owns the cluster security group directly now (no separate
  # cluster-facts-style module); its self-referencing all-protocol rule already
  # covers every CNI's control-plane/pod-to-pod traffic regardless of the cni value.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol == "-1"
    error_message = "the cluster SG's self-referencing rule must remain all-protocol, CNI-agnostic"
  }
}
