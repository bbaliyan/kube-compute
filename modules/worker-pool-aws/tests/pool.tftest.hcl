# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-mock0000000000001" }
  }
}

run "fixed_pool_attaches_cluster_sg_and_sets_az_label" {
  command = plan
  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  variables {
    cluster_name              = "bharat"
    aws_region                = "eu-west-1"
    k8s_version               = "v1.36.1+k3s1"
    spine_k8s_version         = "v1.36.1+k3s1"
    registration_address      = "10.0.1.5"
    agent_token_ssm_parameter = "/kube-node/bharat/agent-token"
    cluster_security_group_id = "sg-cluster123"
    subnet_id                 = "subnet-worker-a"
    instance_type              = "m7g.large"
    desired_count              = 3
  }
  assert {
    condition     = aws_autoscaling_group.worker.min_size == 3 && aws_autoscaling_group.worker.max_size == 3 && aws_autoscaling_group.worker.desired_capacity == 3
    error_message = "a fixed pool must set min_size = max_size = desired_capacity"
  }
  assert {
    condition     = contains(aws_launch_template.worker.vpc_security_group_ids, "sg-cluster123")
    error_message = "the launch template must attach the spine's cluster security group"
  }
  assert {
    condition     = aws_launch_template.worker.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be enforced"
  }
  assert {
    condition     = strcontains(nonsensitive(module.bootstrap.cloud_init), "--node-label topology.kubernetes.io/zone=eu-west-1a")
    error_message = "the pool must derive the AZ from its subnet and set it as a node label"
  }
  assert {
    condition     = strcontains(nonsensitive(module.bootstrap.cloud_init), "aws ssm get-parameter")
    error_message = "the worker must fetch the agent token from SSM at boot, never embed it"
  }
  assert {
    condition     = !strcontains(nonsensitive(module.bootstrap.cloud_init), "cluster-init")
    error_message = "a worker pool must never render server-only flags"
  }
  assert {
    condition     = output.availability_zone == "eu-west-1a"
    error_message = "availability_zone output must reflect the subnet's AZ"
  }
}
