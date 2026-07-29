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
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  instance_type         = "m7g.large"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
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

run "cluster_sg_self_reference_covers_default_cni" {
  command = plan
  variables {
    cni = "default"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol == "-1"
    error_message = "the cluster SG's self-referencing all-protocol rule must exist and cover the default CNI's ports (Canal: 8472/udp, 6443/tcp, 10250/tcp) without any CNI-specific edit"
  }
}

run "cluster_sg_self_reference_covers_cilium" {
  command = plan
  variables {
    cni = "cilium"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol == "-1"
    error_message = "the cluster SG's self-referencing all-protocol rule must exist and cover cilium's ports (4240/tcp, 4244/tcp, 8472-or-6081/udp, 51871/udp, 6443/tcp, 10250/tcp) identically to the default CNI — switching CNI must never require a security-group edit"
  }
}
