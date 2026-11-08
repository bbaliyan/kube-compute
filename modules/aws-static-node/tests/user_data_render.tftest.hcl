# SPDX-License-Identifier: Apache-2.0
# Pins the rendered user data of every node to a known hash, so a refactor of
# how it is built cannot change what a node boots with.
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1b", vpc_id = "vpc-mock" }
}

variables {
  os_image_ami_id           = "ami-0123456789abcdef0"
  cluster_name              = "demo"
  group_name                = "platform"
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/demo/agent-token"
  security_group_ids        = ["sg-cluster123"]
  subnet_id                 = "subnet-cp-a"
  node_count                = 2
  boot_scripts              = ["echo one", "echo two"]
}

run "user_data_is_unchanged" {
  command = plan

  assert {
    condition     = sha256(aws_instance.node["1"].user_data_base64) == "013bfefad51bed54ecc6260e13e1fa1103458c774735b91b782d208cc4cffb6f"
    error_message = "the first node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.node["1"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.node["2"].user_data_base64) == "5f59ece87169036ea2d2478e1de57bb6e82c40e552da73eef764afd9f83106a2"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.node["2"].user_data_base64)), "?")}"
  }
}
