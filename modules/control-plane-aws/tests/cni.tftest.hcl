# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/cp-lb-mock/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/cp-tg-mock/1234567890123456" }
  }
}

run "single_node_cni_defaults_to_flannel" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.rendered_cloud_init), "--flannel-backend=none")
    error_message = "control_plane_count=1 must default cni to flannel"
  }
}

run "ha_cni_defaults_to_cilium" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    control_plane_count   = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "--flannel-backend=none --disable-network-policy --disable-kube-proxy")
    error_message = "control_plane_count>1 must default cni to cilium on the genesis node"
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init_additional["1"]), "--flannel-backend=none --disable-network-policy --disable-kube-proxy")
    error_message = "additional control-plane nodes must render the same cni default as the genesis node"
  }
}

run "explicit_cni_overrides_single_node_default" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    cni                   = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "--flannel-backend=none")
    error_message = "an explicit cni=cilium must override the single-node flannel default"
  }
}

run "explicit_cni_overrides_ha_default" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    control_plane_count   = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
    cni = "flannel"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.rendered_cloud_init), "--flannel-backend=none")
    error_message = "an explicit cni=flannel must override the HA cilium default"
  }
}

run "invalid_cni_rejected" {
  command = plan
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    cni                   = "calico"
  }
  expect_failures = [var.cni]
}

run "cluster_sg_self_reference_covers_flannel" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    cni                   = "flannel"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol == "-1"
    error_message = "the cluster SG's self-referencing all-protocol rule must exist and cover flannel's ports (8472/udp, 6443/tcp, 10250/tcp) without any CNI-specific edit"
  }
}

run "cluster_sg_self_reference_covers_cilium" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    cni                   = "cilium"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.cluster_self.ip_protocol == "-1"
    error_message = "the cluster SG's self-referencing all-protocol rule must exist and cover cilium's ports (4240/tcp, 4244/tcp, 8472-or-6081/udp, 51871/udp, 6443/tcp, 10250/tcp) identically to flannel — switching CNI must never require a security-group edit"
  }
}
