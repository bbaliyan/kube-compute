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
}

run "user_data_is_unchanged" {
  command = apply

  assert {
    condition     = sha256(aws_instance.control_plane["0"].user_data_base64) == "18d3b1816d463fea35e88b51667f4dd4e8160628ae0a8e801e47357cf67fc31c"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["0"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["1"].user_data_base64) == "a64e42ba304a1182fc594f7e824b6e600d8589a6621b55ad7d2640cf3b38208e"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["1"].user_data_base64)), "?")}"
  }

  assert {
    condition     = sha256(aws_instance.control_plane["2"].user_data_base64) == "be396f69a5b1b92c2e2a6f4d2d2338ae576bdc0c04183b48d34f64c847522713"
    error_message = "the third node user data must render as before: got ${try(nonsensitive(sha256(aws_instance.control_plane["2"].user_data_base64)), "?")}"
  }
}
