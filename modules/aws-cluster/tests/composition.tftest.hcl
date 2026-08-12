# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "no_pools_creates_only_control_plane" {
  command = plan

  assert {
    condition     = length(module.node_pools) == 0
    error_message = "empty node_pools map must create zero worker-pool module instances"
  }
}

run "one_pool_creates_its_workers_and_shares_the_agent_token" {
  # apply (not plan): the pool's registration_address/agent_token_ssm_parameter/
  # cluster_security_group_id inputs read module.control_plane's resource
  # outputs, which are unknown at plan time — matches the precedent in
  # proxmox-cluster's own composition.tftest.hcl.
  command = apply

  variables {
    node_pools = {
      pool-a = {
        subnet_id       = "subnet-abc"
        os_image_ami_id = "ami-0123456789abcdef0"
        desired_count   = 2
      }
    }
  }

  assert {
    condition     = length(module.node_pools) == 1
    error_message = "one node_pools entry must create exactly one worker-pool module instance"
  }

  assert {
    condition     = output.node_pools["pool-a"].node_provider == "aws"
    error_message = "the module's own node_pools output must surface the pool's node_provider"
  }

  assert {
    condition     = output.agent_token_ssm_parameter == module.control_plane.agent_token_ssm_parameter
    error_message = "the module's own agent_token_ssm_parameter output must equal control_plane's, proving the same-state wiring"
  }
}
