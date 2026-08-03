# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

run "agent_token_stored_as_securestring_and_exposed_by_output" {
  command = plan
  variables {
    cluster_name = "bharat"
    vpc_id       = "vpc-mock123"
  }

  assert {
    condition     = aws_ssm_parameter.agent_token.type == "SecureString"
    error_message = "agent-token SSM parameter must be stored as SecureString, never plaintext"
  }
  assert {
    condition     = output.agent_token_ssm_parameter == aws_ssm_parameter.agent_token.name
    error_message = "agent_token_ssm_parameter output must expose the SSM parameter's own name"
  }
}

run "vpc_name_resolves_to_security_group_vpc_id" {
  command = plan
  variables {
    cluster_name = "bharat"
    vpc_name     = "my-vpc"
  }

  assert {
    condition     = aws_security_group.cluster.vpc_id == data.aws_vpc.named[0].id
    error_message = "security group must attach to the VPC resolved from vpc_name when vpc_id isn't given"
  }
}

run "neither_vpc_id_nor_vpc_name_fails_validation" {
  command = plan
  variables {
    cluster_name = "bharat"
  }

  expect_failures = [var.vpc_name]
}
