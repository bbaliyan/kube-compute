# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {}

variables {
  name_prefix = "kube-compute-example-"
  tags        = { ManagedBy = "kube-compute" }
  aws_region  = "eu-west-1"
}

run "defaults_attach_ssm_and_ebs_csi_without_an_agent_token_policy" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.ssm_core.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "the role must carry the SSM core policy"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.ebs_csi) == 1 && length(aws_iam_role_policy.agent_token) == 0
    error_message = "EBS CSI must be on by default and the agent token policy off"
  }

  assert {
    condition     = jsondecode(aws_iam_role.node.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com"
    error_message = "only EC2 may assume the node role"
  }
}

run "ebs_csi_can_be_left_off" {
  command = plan

  variables {
    attach_ebs_csi_policy = false
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.ebs_csi) == 0
    error_message = "attach_ebs_csi_policy = false must drop the EBS CSI attachment"
  }
}

run "agent_token_policy_reads_only_the_named_parameter" {
  command = plan

  variables {
    agent_token = {
      policy_name   = "kube-compute-example-agent-token-read"
      ssm_parameter = "/kube-compute/example/agent-token"
    }
  }

  assert {
    condition     = aws_iam_role_policy.agent_token[0].name == "kube-compute-example-agent-token-read"
    error_message = "the policy must take its name from the caller"
  }

  assert {
    condition     = endswith(jsondecode(aws_iam_role_policy.agent_token[0].policy).Statement[0].Resource, ":parameter/kube-compute/example/agent-token")
    error_message = "ssm:GetParameter must be scoped to the one parameter"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.agent_token[0].policy).Statement[1].Condition.StringEquals["kms:ViaService"] == "ssm.eu-west-1.amazonaws.com"
    error_message = "kms:Decrypt must be limited to calls made through SSM in the region"
  }
}
