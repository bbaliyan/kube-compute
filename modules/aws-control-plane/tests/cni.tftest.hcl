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
  cluster_name              = "bharat"
  aws_region                = "eu-west-1"
  instance_type             = "m7g.large"
  allowed_ingress_cidrs     = ["10.0.0.0/8"]
  subnet_id                 = "subnet-abc"
  cluster_token             = "test-cluster-token-0123456789"
  cluster_agent_token       = "test-agent-token-0123456789"
  cluster_security_group_id = "sg-mock-cluster"
}

# NOTE: the run blocks that used to live here (single_node_cni_defaults_to_default,
# ha_cni_defaults_to_cilium, explicit_cni_overrides_single_node_default,
# explicit_cni_overrides_ha_default) asserted on the `rendered_cloud_init`/
# `rendered_cloud_init_additional` outputs. Those outputs no longer exist — this
# module now hands `cni` to `node-bootstrap`, which renders it into config.yaml via
# Ansible at real-apply time, not into a Terraform-visible string. There is currently
# no automated test coverage for cni-default/override rendering; see rke2-ansible-bootstrap
# Ticket 14's resolution notes for the follow-up this needs.

run "invalid_cni_rejected" {
  command = plan
  variables {
    cni = "calico"
  }
  expect_failures = [var.cni]
}

# NOTE: cluster_sg_self_reference_covers_default_cni and cluster_sg_self_reference_covers_cilium
# used to assert on aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol — that resource
# (and the aws_security_group.cluster it belonged to) no longer exist in this module. This task
# rewired aws-control-plane to consume the cluster SG as var.cluster_security_group_id instead of
# creating it, so the self-referencing all-protocol rule (and its CNI-agnostic coverage) is now
# aws-cluster-facts's responsibility, tested there instead.
