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
  argocd_manifest_url         = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256      = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
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
    condition     = sha256(aws_instance.control_plane["0"].user_data_base64) == "76bf3ae2667b1abdfee51c73b6a28ca1ad5c6a9c69f390605a4f62ea9844c493"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["0"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["1"].user_data_base64) == "571216f8aec33fcba6ec5de8e53428d098361eea6881949bad6e5dfcae06997f"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["1"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["2"].user_data_base64) == "6cdc46a4d5e4fe8979c97c3b22fd25a04ad43fd3257e6ce5443224eb33117d67"
    error_message = "the third node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["2"].user_data_base64)), "?")}"
  }
}
