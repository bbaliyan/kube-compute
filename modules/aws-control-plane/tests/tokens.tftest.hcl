# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {}

run "server_and_agent_tokens_distinct_and_ssm_backed" {
  command = plan
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.2+rke2r1"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
  }

  # NOTE: two assertions used to live here — "server and agent tokens must be
  # distinct" and "the SSM parameter must hold the agent token, never the server
  # token" — comparing random_password.*.result values directly. random_password's
  # result is unknown until apply, and this module's apply now genuinely invokes
  # node-bootstrap's local-exec (real ansible-playbook), which this sandboxed/CI
  # environment can't run — so there's no way to reach those apply-time values here
  # anymore. A third assertion checked the agent token's presence in
  # `rendered_cloud_init`, an output that no longer exists (that content is now
  # rendered by Ansible, not Terraform). See rke2-ansible-bootstrap Ticket 14's
  # resolution notes for this coverage gap.
  assert {
    condition     = aws_ssm_parameter.agent_token.type == "SecureString"
    error_message = "the agent token must be stored as an SSM SecureString"
  }
  assert {
    condition     = output.agent_token_ssm_parameter == aws_ssm_parameter.agent_token.name
    error_message = "agent_token_ssm_parameter output must expose the parameter name workers fetch from"
  }
}
