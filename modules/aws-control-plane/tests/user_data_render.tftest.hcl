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
    condition     = sha256(aws_instance.control_plane["0"].user_data_base64) == "3180d29b47c079abbce9e8a10182690515818e40248cfe22f5831a7489558f94"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["0"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["1"].user_data_base64) == "3aa4b3a064035ea8bf043e2fe22fbcfa22c1e35e74c3998aa60ce8cb4b458169"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["1"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["2"].user_data_base64) == "270c6f3255727ebf2c716a201a90e684351b9b46a2782389f939a2fcc7c7f85b"
    error_message = "the third node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["2"].user_data_base64)), "?")}"
  }
}
