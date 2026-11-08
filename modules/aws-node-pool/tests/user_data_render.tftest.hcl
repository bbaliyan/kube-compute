# SPDX-License-Identifier: Apache-2.0
# Pins the rendered user data of every launch template to a known hash, so a
# refactor of how it is built cannot change what a node boots with.
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["x86_64"] }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0", root_device_name = "/dev/sda1" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  os_image_ami_id           = "ami-0123456789abcdef0"
  cluster_name              = "demo"
  group_name                = "workers"
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/demo/agent-token"
  cluster_security_group_id = "sg-cluster123"
  subnet_id                 = "subnet-worker-a"
  instance_type_max_sizes   = { "t3a.large" = 3 }
}

run "user_data_is_unchanged" {
  command = plan

  assert {
    condition     = sha256(aws_launch_template.node["t3a.large"].user_data) == "566f904ac60eb3890adc3acdba35241377d12c6a88cc1c31079da24993343f52"
    error_message = "the launch template user data must render as before: got ${try(nonsensitive(sha256(aws_launch_template.node["t3a.large"].user_data)), "?")}"
  }
}
