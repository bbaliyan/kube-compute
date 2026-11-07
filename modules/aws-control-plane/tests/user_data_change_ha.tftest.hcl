# SPDX-License-Identifier: Apache-2.0
# What a change to the rendered user data does to a three-node control plane.
# See user_data_change.tftest.hcl for how a run tells a kept node from a
# replaced one, and for what a mock cannot show.
#
# Only the first node's new render is an output, so only the first node shows
# a replacement. For the additional nodes these runs show the hashes that
# trigger their replacement, not the replacement itself.
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
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  control_plane_count   = 3
  control_plane_subnets = {
    "eu-west-1a" = "subnet-az-a"
    "eu-west-1b" = "subnet-az-b"
    "eu-west-1c" = "subnet-az-c"
  }
  platform_extra_helm_parameters = {
    "global.example" = "one"
  }
}

run "create" {
  command = apply

  assert {
    condition     = toset(keys(terraform_data.user_data)) == toset(["0", "1", "2"])
    error_message = "every control-plane node must have a user data hash entry"
  }
  assert {
    condition     = alltrue([for t in values(terraform_data.user_data) : t.triggers_replace == null])
    error_message = "by default no user data hash may be tracked"
  }
}

run "default_keeps_the_nodes_when_shared_user_data_changes" {
  command = apply

  variables {
    registry_mirror_url = "https://mirror.example.test"
  }

  assert {
    condition     = aws_instance.control_plane.user_data_base64 != output.connectivity_user_data_base64
    error_message = "by default a user data change must not replace the first node"
  }
}

run "opt_in_tracks_every_node" {
  command = apply

  variables {
    registry_mirror_url         = "https://mirror.example.test"
    replace_on_user_data_change = true
  }

  assert {
    condition     = alltrue([for t in values(terraform_data.user_data) : t.triggers_replace == t.input])
    error_message = "with replace_on_user_data_change every node's current user data hash must be tracked"
  }
}

run "opt_in_replaces_the_first_node_for_a_helm_parameter" {
  command = apply

  variables {
    registry_mirror_url         = "https://mirror.example.test"
    replace_on_user_data_change = true
    platform_extra_helm_parameters = {
      "global.example" = "two"
    }
  }

  assert {
    condition     = aws_instance.control_plane.user_data_base64 == output.connectivity_user_data_base64
    error_message = "with replace_on_user_data_change a user data change must replace the first node"
  }
}
