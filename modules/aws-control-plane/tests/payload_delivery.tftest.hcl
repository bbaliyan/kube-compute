# SPDX-License-Identifier: Apache-2.0
# Guards the pointer form of user data: that it is genuinely absent by default,
# that what the node reassembles is exactly what Terraform rendered, that the
# stub stays small enough for the limit it exists to respect, and that a payload
# change still counts as a user-data change.
# Static ARNs for the HA run below, for the reason ha_control_plane.tftest.hcl
# records: the provider validates an ARN it was handed from another resource, and a
# mock's random string is not ARN-shaped.
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
  instance_type         = "m7g.large"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-x"
}

run "inline_by_default" {
  command = apply

  assert {
    condition     = length(aws_ssm_parameter.node_payload) == 0
    error_message = "nothing belongs in SSM while the payload travels in user data -- every existing instance is on this path and its user data must not change"
  }
  assert {
    condition     = length(aws_iam_role_policy.node_payload_read) == 0
    error_message = "no node should be granted reads on a payload prefix that holds nothing"
  }
  assert {
    condition     = nonsensitive(local.effective_user_data["0"]) == nonsensitive(local.combined_user_data["0"])
    error_message = "the default path must be the MIME cloud-config, byte for byte"
  }
}

run "pointer_form_reassembles_to_exactly_what_was_rendered" {
  command = apply

  variables {
    bootstrap_payload_in_ssm = true
  }

  # The one thing chunking can get wrong. Reassembled in part order, the pieces
  # must be the rendered payload and nothing else -- a lost or reordered piece
  # would only show up as a node that fails to gunzip its own boot script.
  # The one thing this can get wrong. Reassembled in order and stripped of the
  # padding that fills the last pieces, the parameters must be the rendered payload
  # and nothing else -- a lost or reordered piece would surface only as a node that
  # cannot gunzip its own boot script.
  assert {
    condition = trimspace(join("", [
      for i in range(local.payload_piece_count) :
      aws_ssm_parameter.node_payload["0/${i + 1}"].value
    ])) == nonsensitive(local.node_payload_encoded["0"])
    error_message = "the pieces do not reassemble into the rendered payload"
  }
  assert {
    condition = alltrue([
      for k, c in local.node_payload_pieces : nonsensitive(length(c)) == 4000
    ])
    error_message = "every piece must be exactly the chunk size: under 4096 so an SSM Standard parameter holds it, and non-empty so SSM accepts it"
  }
  assert {
    condition     = length(aws_ssm_parameter.node_payload) == local.payload_piece_count
    error_message = "one parameter per reserved piece, and no orphans"
  }
  assert {
    condition     = alltrue([for p in values(aws_ssm_parameter.node_payload) : p.type == "SecureString" && p.tier == "Standard"])
    error_message = "a node's whole bootstrap configuration is a secret, and Standard tier is what makes storing it free"
  }
  assert {
    condition     = length(aws_iam_role_policy.node_payload_read) == 1
    error_message = "the node cannot read its own payload without this policy, and it fetches before RKE2 starts"
  }
}

run "the_stub_is_small_and_stays_small" {
  command = apply

  variables {
    bootstrap_payload_in_ssm = true
    # A payload far larger than any real cluster's: whatever it grows to, the stub
    # only grows by one fetch per 4000 bytes, which is the property being asserted.
    extra_server_manifests = {
      "90-big.yaml" = "# filler\n#0123456789012345678901234567890123456789012345678901234567890123456789\n"
    }
  }

  assert {
    condition     = floor(nonsensitive(length(base64gzip(local.effective_user_data["0"]))) / 4) * 3 < 4096
    error_message = "user data is a pointer now: if it is anywhere near EC2's 16384-byte limit, something payload-sized has crept back into it"
  }
  assert {
    condition     = strcontains(nonsensitive(local.effective_user_data["0"]), "payload-sha256: ${sha256(nonsensitive(local.node_payload_encoded["0"]))}")
    error_message = "the stub must carry the payload's hash, or a changed payload leaves user data unchanged and user_data_replace_on_change stops replacing the instance"
  }
  assert {
    condition = alltrue([
      for i in range(local.payload_piece_count) :
      strcontains(nonsensitive(local.effective_user_data["0"]), aws_ssm_parameter.node_payload["0/${i + 1}"].name)
    ])
    error_message = "every piece must be named in the stub, in order, or the node reassembles a partial payload"
  }
}

run "every_control_plane_node_gets_its_own_payload" {
  command = apply

  variables {
    bootstrap_payload_in_ssm = true
    control_plane_count      = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-a"
      "eu-west-1b" = "subnet-b"
      "eu-west-1c" = "subnet-c"
    }
  }

  assert {
    condition     = length(local.node_payload_encoded) == 3 && length(aws_ssm_parameter.node_payload) == 3 * local.payload_piece_count
    error_message = "each control-plane node boots from its own payload -- they differ by hostname and by role, genesis versus join"
  }
  assert {
    condition = alltrue([
      for k in keys(local.node_payload_encoded) :
      strcontains(nonsensitive(local.effective_user_data[k]), "payload-sha256: ${sha256(nonsensitive(local.node_payload_encoded[k]))}")
    ])
    error_message = "each node's stub must point at its own payload"
  }
}
