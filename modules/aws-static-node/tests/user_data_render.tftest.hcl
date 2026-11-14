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
}

run "user_data_is_unchanged" {
  command = plan

  assert {
    condition     = sha256(aws_instance.node["1"].user_data_base64) == "b10eb3685229d4a4e27326b608040d43c584f37f0aab85ad06aa3cdfb0d41520"
    error_message = "the first node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.node["1"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.node["2"].user_data_base64) == "609aee1793685ddf17ea0d798b0725d908ee7f600b75b7a1e9f13a596e7f947f"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.node["2"].user_data_base64)), "?")}"
  }
}
