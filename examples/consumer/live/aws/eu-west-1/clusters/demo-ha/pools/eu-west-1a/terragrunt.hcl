include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "common" {
  path   = find_in_parent_folders("common.hcl")
  expose = true
}

include "region" {
  path   = find_in_parent_folders("region.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/bbaliyan/kube-node.git//modules/worker-pool-aws?ref=0e2723028b30a8d10b3e4d7bfcc732f846465b89"
}

dependency "spine" {
  config_path = "../../spine"

  # Only needed so `terragrunt run validate`/`plan` work without first applying the
  # spine — a real consumer applies the spine before its pools and these mocks are
  # never used.
  mock_outputs = {
    registration_address      = "mock-nlb.eu-west-1.elb.amazonaws.com"
    agent_token_ssm_parameter = "/kube-node/demo-ha/agent-token"
    cluster_security_group_id = "sg-0123456789abcdef0"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "init"]
}

locals {
  cluster_name = "demo-ha"
  k8s_version  = "v1.36.1+k3s1" # must match the spine unit's k8s_version above
}

# Pools are AZ-pinned by design: one pool = one subnet = one availability zone.
inputs = {
  cluster_name  = local.cluster_name
  aws_region    = include.region.locals.aws_region
  instance_type = "m7g.large"
  desired_count = 2

  k8s_version       = local.k8s_version
  spine_k8s_version = local.k8s_version

  registration_address      = dependency.spine.outputs.registration_address
  agent_token_ssm_parameter = dependency.spine.outputs.agent_token_ssm_parameter
  cluster_security_group_id = dependency.spine.outputs.cluster_security_group_id

  subnet_id = "subnet-0123456789abcdefa"
}
