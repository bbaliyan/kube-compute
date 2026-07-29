# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

run "fixed_pool_is_discrete_instances_on_the_cluster_sg" {
  command = plan
  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  variables {
    cluster_name              = "bharat"
    aws_region                = "eu-west-1"
    k8s_version               = "v1.36.2+rke2r1"
    registration_address      = "10.0.1.5"
    agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
    cluster_security_group_id = "sg-cluster123"
    subnet_id                 = "subnet-worker-a"
    instance_type             = "m7g.large"
    desired_count             = 3
  }
  # Fixed pool = exactly desired_count discrete instances (no ASG).
  assert {
    condition     = length(aws_instance.worker) == 3
    error_message = "a fixed pool must create exactly desired_count discrete instances"
  }
  assert {
    condition     = contains(aws_instance.worker[0].vpc_security_group_ids, "sg-cluster123")
    error_message = "every worker must attach the control plane's cluster security group"
  }
  assert {
    condition     = aws_instance.worker[0].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be enforced"
  }
  # Connectivity-only user-data: SSM agent enabled, never an RKE2/cluster payload.
  assert {
    condition     = strcontains(aws_instance.worker[0].user_data, "amazon-ssm-agent")
    error_message = "worker user-data must enable the SSM agent for the Ansible transport"
  }
  assert {
    condition     = !strcontains(aws_instance.worker[0].user_data, "cluster-init")
    error_message = "worker user-data must carry no server/cluster bootstrap payload"
  }
  assert {
    condition     = output.availability_zone == "eu-west-1a"
    error_message = "availability_zone output must reflect the subnet's AZ"
  }
  assert {
    condition     = length(output.instance_ids) == 3
    error_message = "instance_ids must list every worker for verb-script targeting"
  }
}
