# SPDX-License-Identifier: Apache-2.0
# What a change to the rendered user data does to a running control-plane node.
# The runs share one state and run in order: each one applies on top of the last.
# Every run is an apply, because the payload carries a generated token and is
# unknown at plan.
#
# How a run tells a kept node from a replaced one: the instance ignores changes
# to user_data_base64, so a kept node keeps the user data it was created with,
# and a replaced node gets the new render. connectivity_user_data_base64 is
# that new render for the first node.
#
# What a mock cannot show:
# - The mock gives an instance the same id each time it creates one, so an id
#   does not show a replacement. A run that changes no user data, such as one
#   that only turns the opt-in off, cannot show that the node was kept.
# - The real EC2 API is not called, so these runs do not prove that AWS keeps
#   the node running, or what cloud-init does on a replaced node.
# - A test cannot start from the state of an older module version, so the
#   one-time replacement on upgrade is not shown.
# They show what OpenTofu plans and stores for the module's own resources.
mock_provider "aws" {}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  platform_extra_helm_parameters = {
    "global.example" = "one"
  }
}

run "create" {
  command = apply

  assert {
    condition     = aws_instance.control_plane.user_data_base64 == output.connectivity_user_data_base64
    error_message = "a new node must boot with the current user data"
  }
  assert {
    condition     = terraform_data.user_data["0"].triggers_replace == null
    error_message = "by default the user data hash must not be tracked"
  }
}

run "default_keeps_the_node_when_a_helm_parameter_changes" {
  command = apply

  variables {
    platform_extra_helm_parameters = {
      "global.example" = "two"
    }
  }

  assert {
    condition     = aws_instance.control_plane.user_data_base64 != output.connectivity_user_data_base64
    error_message = "by default a user data change must not replace the control-plane node"
  }
}

run "turning_the_opt_in_on_replaces_a_node_changed_while_it_was_off" {
  command = apply

  variables {
    replace_on_user_data_change = true
    platform_extra_helm_parameters = {
      "global.example" = "two"
    }
  }

  assert {
    condition     = aws_instance.control_plane.user_data_base64 == output.connectivity_user_data_base64
    error_message = "the user data changed while the opt-in was off, so turning it on must replace the node"
  }
}

run "opt_in_replaces_the_node_when_a_helm_parameter_changes" {
  command = apply

  variables {
    replace_on_user_data_change = true
    platform_extra_helm_parameters = {
      "global.example" = "three"
    }
  }

  assert {
    condition     = aws_instance.control_plane.user_data_base64 == output.connectivity_user_data_base64
    error_message = "with replace_on_user_data_change a user data change must replace the node"
  }
}

run "turning_the_opt_in_off" {
  command = apply

  variables {
    platform_extra_helm_parameters = {
      "global.example" = "three"
    }
  }

  assert {
    condition     = terraform_data.user_data["0"].triggers_replace == null
    error_message = "with the opt-in off the user data hash must not be tracked"
  }
}

run "after_the_opt_in_is_off_a_change_keeps_the_node" {
  command = apply

  variables {
    platform_extra_helm_parameters = {
      "global.example" = "four"
    }
  }

  assert {
    condition     = aws_instance.control_plane.user_data_base64 != output.connectivity_user_data_base64
    error_message = "after the opt-in is turned off, a user data change must not replace the node"
  }
}
