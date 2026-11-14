# SPDX-License-Identifier: Apache-2.0
# Pod identity on the control plane: the issuer flag on every server, the key publish step on
# genesis only, and the provider ID step on every server. Plan only: nothing is created.
mock_provider "aws" {}

override_resource {
  target = random_password.server_token
  values = { result = "server-token-for-the-test" }
}

override_resource {
  target = random_password.agent_token
  values = { result = "agent-token-for-the-test" }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  os_image_ami_id             = "ami-0123456789abcdef0"
  cluster_name                = "pi"
  aws_region                  = "eu-west-1"
  allowed_ingress_cidrs       = ["10.0.0.0/8"]
  subnet_id                   = "subnet-abc"
  control_plane_count         = 3
  endpoint_mode               = "static"
  static_registration_address = "cp.pi.example.test"
  control_plane_subnets = {
    "eu-west-1a" = "subnet-az-a"
    "eu-west-1b" = "subnet-az-b"
    "eu-west-1c" = "subnet-az-c"
  }
}

run "pod_identity_is_off_by_default" {
  command = plan

  assert {
    condition     = !contains(module.node_bootstrap["0"].boot_steps, "genesis-publish-service-account-keys") && !contains(module.node_bootstrap["0"].boot_steps, "aws-provider-id")
    error_message = "no publish step and no provider ID step unless pod identity is on"
  }
  assert {
    condition = !anytrue([
      for k in ["0", "1", "2"] : anytrue([
        for f in yamldecode(module.node_bootstrap[k].cloud_init_user_data).write_files :
        strcontains(base64decode(f.content), "service-account-issuer")
        if try(f.encoding, "") == "b64"
      ])
    ])
    error_message = "no server may name an issuer unless pod identity is on"
  }
}

run "pod_identity_on" {
  command = plan

  variables {
    pod_identity = {
      issuer_url  = "https://d111111abcdef8.cloudfront.net"
      keys_bucket = "keys-bucket"
    }
  }

  assert {
    condition     = contains(module.node_bootstrap["0"].boot_steps, "genesis-publish-service-account-keys") && !contains(module.node_bootstrap["1"].boot_steps, "genesis-publish-service-account-keys") && !contains(module.node_bootstrap["2"].boot_steps, "genesis-publish-service-account-keys")
    error_message = "only the genesis node publishes the keys"
  }
  assert {
    condition     = alltrue([for k in ["0", "1", "2"] : contains(module.node_bootstrap[k].boot_steps, "aws-provider-id")])
    error_message = "every server must set its providerID and labels"
  }
  assert {
    condition = alltrue([
      for k in ["0", "1", "2"] : anytrue([
        for f in yamldecode(module.node_bootstrap[k].cloud_init_user_data).write_files :
        strcontains(base64decode(f.content), "service-account-issuer=https://d111111abcdef8.cloudfront.net\"")
        if try(f.encoding, "") == "b64"
      ])
    ])
    error_message = "every server must carry the exact issuer in its RKE2 config"
  }
}
