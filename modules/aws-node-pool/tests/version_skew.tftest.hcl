# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

run "pool_version_equal_to_control_plane_is_accepted" {
  command = plan
  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  variables {
    cluster_name              = "bharat"
    aws_region                = "eu-west-1"
    k8s_version               = "v1.36.2+rke2r1"
    control_plane_k8s_version = "v1.36.2+rke2r1"
    registration_address      = "10.0.1.5"
    agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
    cluster_security_group_id = "sg-cluster123"
    subnet_id                 = "subnet-worker-a"
  }
  assert {
    condition     = length(aws_instance.worker) >= 1
    error_message = "equal pool/control-plane versions must plan successfully"
  }
}

run "pool_version_older_than_control_plane_is_accepted" {
  command = plan
  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  variables {
    cluster_name              = "bharat"
    aws_region                = "eu-west-1"
    k8s_version               = "v1.35.5+rke2r1"
    control_plane_k8s_version = "v1.36.2+rke2r1"
    registration_address      = "10.0.1.5"
    agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
    cluster_security_group_id = "sg-cluster123"
    subnet_id                 = "subnet-worker-a"
  }
  assert {
    condition     = length(aws_instance.worker) >= 1
    error_message = "an older pool version (kubelet trailing the API server) must be accepted"
  }
}

run "pool_version_newer_than_control_plane_is_rejected" {
  command = plan
  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  variables {
    cluster_name              = "bharat"
    aws_region                = "eu-west-1"
    k8s_version               = "v1.37.0+rke2r1"
    control_plane_k8s_version = "v1.36.2+rke2r1"
    registration_address      = "10.0.1.5"
    agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
    cluster_security_group_id = "sg-cluster123"
    subnet_id                 = "subnet-worker-a"
  }
  expect_failures = [aws_instance.worker]
}
