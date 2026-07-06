# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

run "server_and_agent_tokens_distinct_and_ssm_backed" {
  command = apply
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.1+k3s1"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
  }

  assert {
    condition     = nonsensitive(random_password.server_token.result) != nonsensitive(random_password.agent_token.result)
    error_message = "server and agent tokens must be distinct (least privilege: an agent token must not double as a server token)"
  }
  assert {
    condition     = aws_ssm_parameter.agent_token.type == "SecureString"
    error_message = "the agent token must be stored as an SSM SecureString"
  }
  assert {
    condition     = nonsensitive(aws_ssm_parameter.agent_token.value) == nonsensitive(random_password.agent_token.result)
    error_message = "the SSM parameter must hold the agent token, never the server token"
  }
  assert {
    condition     = output.agent_token_ssm_parameter == aws_ssm_parameter.agent_token.name
    error_message = "agent_token_ssm_parameter output must expose the parameter name workers fetch from"
  }
}
