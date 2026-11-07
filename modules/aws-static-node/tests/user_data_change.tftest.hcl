# SPDX-License-Identifier: Apache-2.0
# Which user data hashes a group tracks. A change to a tracked hash replaces
# the node; aws-control-plane's user_data_change test shows that behaviour,
# which this module shares. The runs share one state and run in order.
#
# What a mock cannot show: the module has no output with a node's new render,
# and the mock gives an instance the same id each time it creates one, so these
# runs cannot tell a kept node from a replaced one. They show the hashes that
# trigger a replacement, and that the module applies and destroys with them.
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
}

variables {
  cluster_name              = "bharat"
  group_name                = "platform"
  node_count                = 2
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
  security_group_ids        = ["sg-cluster123"]
  subnet_id                 = "subnet-cp-a"
  node_labels               = { "workload" = "one" }
}

run "default_tracks_no_hash" {
  command = apply

  assert {
    condition     = toset(keys(terraform_data.user_data)) == toset(["1", "2"])
    error_message = "every node must have a user data hash entry"
  }
  assert {
    condition     = alltrue([for t in values(terraform_data.user_data) : t.triggers_replace == null])
    error_message = "by default no user data hash may be tracked"
  }
}

run "opt_in_tracks_every_node" {
  command = apply

  variables {
    node_labels                 = { "workload" = "two" }
    replace_on_user_data_change = true
  }

  assert {
    condition     = alltrue([for t in values(terraform_data.user_data) : t.triggers_replace == t.input])
    error_message = "with replace_on_user_data_change every node's current user data hash must be tracked"
  }
}
