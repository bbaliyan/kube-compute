# SPDX-License-Identifier: Apache-2.0
# Pins the rendered user data of every control-plane node to a known hash, so a
# refactor of how it is built cannot change what a node boots with. The tokens
# are fixed, and the registration address is static, so the render is stable.
mock_provider "aws" {}

override_resource {
  target = random_password.server_token
  values = { result = "server-token-for-the-render-test" }
}

override_resource {
  target = random_password.agent_token
  values = { result = "agent-token-for-the-render-test" }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  os_image_ami_id             = "ami-0123456789abcdef0"
  cluster_name                = "demo"
  aws_region                  = "eu-west-1"
  allowed_ingress_cidrs       = ["10.0.0.0/8"]
  subnet_id                   = "subnet-abc"
  control_plane_count         = 3
  endpoint_mode               = "static"
  static_registration_address = "cp.demo.example.test"
  control_plane_subnets = {
    "eu-west-1a" = "subnet-az-a"
    "eu-west-1b" = "subnet-az-b"
    "eu-west-1c" = "subnet-az-c"
  }
  boot_scripts = ["echo one", "echo two"]
}

run "user_data_is_unchanged" {
  command = apply

  assert {
    condition     = sha256(aws_instance.control_plane["0"].user_data_base64) == "dd051201dd7635e1da57a2c3576fa1a8d680be053b11cd5ef79e602c12c28ffa"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["0"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["1"].user_data_base64) == "764ce949f70424c6f4e32c7f388dde3a682ff4747a7fa05cf3c9b4035d09cb6f"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["1"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["2"].user_data_base64) == "7db800654e10ecc2e5b9566f82d0fb5c84c0dbb37995c39e04e4f0f6376c98d7"
    error_message = "the third node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["2"].user_data_base64)), "?")}"
  }
}
