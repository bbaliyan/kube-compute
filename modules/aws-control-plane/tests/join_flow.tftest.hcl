# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

variables {
  cluster_name              = "bharat"
  k8s_version               = "v1.36.2+rke2r1"
  aws_region                = "eu-west-1"
  instance_type             = "m7g.large"
  allowed_ingress_cidrs     = ["10.0.0.0/8"]
  subnet_id                 = "subnet-abc"
  cluster_token             = "test-cluster-token-0123456789"
  cluster_agent_token       = "test-agent-token-0123456789"
  cluster_security_group_id = "sg-mock-cluster"
}

run "cluster_sg_is_self_referencing" {
  command = plan
  # NOTE: the "cluster SG allows traffic sourced from itself" and
  # "cluster_security_group_id output exposes the cluster SG id" assertions that used
  # to live here referenced aws_security_group.cluster and the now-removed
  # cluster_security_group_id output. This task rewired aws-control-plane to consume
  # the cluster SG as var.cluster_security_group_id instead of creating it — both the
  # self-referencing-ingress-rule behavior and the SG id are now aws-cluster-facts's
  # responsibility, tested there instead.
  assert {
    condition     = contains(aws_instance.control_plane.vpc_security_group_ids, var.cluster_security_group_id)
    error_message = "the control-plane instance must attach the cluster SG"
  }
}

run "etcd_sg_is_control_plane_only" {
  command = plan
  assert {
    condition     = aws_vpc_security_group_ingress_rule.etcd_peer.from_port == 2379 && aws_vpc_security_group_ingress_rule.etcd_peer.to_port == 2380
    error_message = "the etcd SG must open exactly 2379-2380"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.etcd_peer.referenced_security_group_id == aws_security_group.control_plane_etcd.id
    error_message = "etcd traffic must be scoped to a control-plane-only SG, not the general cluster SG workers also join"
  }
  assert {
    condition     = contains(aws_instance.control_plane.vpc_security_group_ids, aws_security_group.control_plane_etcd.id)
    error_message = "the control-plane instance must attach the etcd-only SG"
  }
}

run "registration_address_and_node_refs" {
  command = plan
  assert {
    condition     = output.registration_address == aws_instance.control_plane.private_ip
    error_message = "for control_plane_count=1, registration_address must be the sole control-plane node's private IP"
  }
  assert {
    condition     = keys(output.control_plane_node_refs) == ["bharat-cp-1"]
    error_message = "control_plane_node_refs must map a deterministic node name to its ref"
  }
  assert {
    condition     = output.control_plane_node_refs["bharat-cp-1"].instance_id == aws_instance.control_plane.id
    error_message = "each node ref must carry the instance id"
  }
  assert {
    condition     = output.control_plane_node_refs["bharat-cp-1"].provider == "aws"
    error_message = "each node ref must report its provider"
  }
}
