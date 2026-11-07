# SPDX-License-Identifier: Apache-2.0
# The runs share one state, as successive applies of one cluster do. Only the
# candidate subnets are overridden: the subnet a placed cluster keeps comes
# from state, not from a lookup.
#
# override_data targets a whole data source, never one for_each instance, so
# within a run every candidate mocks to the same id and free-IP count. Each run
# gives the candidates a new id, so a cluster that moved would show it.
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

variables {
  cluster_name          = "pool"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_names          = ["private-az1", "private-az2"]
}

run "a_new_cluster_takes_a_candidate_with_room" {
  command = apply

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-first", available_ip_address_count = 250 }
  }

  assert {
    condition     = output.subnet_id == "subnet-first"
    error_message = "a new cluster must be placed in a candidate with room"
  }
  assert {
    condition     = aws_instance.control_plane.subnet_id == "subnet-first"
    error_message = "the control plane must launch into the chosen subnet"
  }
}

run "the_cluster_stays_when_the_first_candidate_is_full" {
  command = apply

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-elsewhere", available_ip_address_count = 0 }
  }

  assert {
    condition     = output.subnet_id == "subnet-first"
    error_message = "a placed cluster must stay in its subnet when the first candidate has no room"
  }
  assert {
    condition     = aws_instance.control_plane.subnet_id == "subnet-first"
    error_message = "the control plane must not move to another subnet"
  }
}

run "the_cluster_stays_when_the_candidates_are_reordered" {
  command = apply

  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-roomier", available_ip_address_count = 250 }
  }

  variables {
    subnet_names = ["private-az2", "private-az1"]
  }

  assert {
    condition     = output.subnet_id == "subnet-first"
    error_message = "a roomier first candidate must not pull a placed cluster out of its subnet"
  }
  assert {
    condition     = aws_instance.control_plane.subnet_id == "subnet-first"
    error_message = "the control plane must not move to another subnet"
  }
}
