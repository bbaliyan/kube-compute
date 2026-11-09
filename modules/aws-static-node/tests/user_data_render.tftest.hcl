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
    condition     = sha256(aws_instance.node["1"].user_data_base64) == "a3a628c17ee69eaf3dd592e7ad5883c687bfbbfdaa9aff73b236bd0e7d0b04b0"
    error_message = "the first node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.node["1"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.node["2"].user_data_base64) == "41ea6444261a2c0ee062d775d27d79aacd434372035ed1c9520559d8d0b75e78"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.node["2"].user_data_base64)), "?")}"
  }
}
