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
