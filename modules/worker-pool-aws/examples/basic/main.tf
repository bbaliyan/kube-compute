# SPDX-License-Identifier: Apache-2.0
# Minimal worker-pool-aws usage against an existing spine-aws. Placeholder values —
# replace for your environment. For `tofu plan` illustration only (no backend wired).
provider "aws" {
  region = "eu-west-1"
}

# In a real consumer repo this comes from a terragrunt `dependency "spine"` block reading
# the spine's outputs. Here the values are hardcoded to illustrate the shape expected.
module "worker_pool" {
  source = "../.."

  cluster_name  = "demo"
  aws_region    = "eu-west-1"
  instance_type = "m7g.large"
  desired_count = 2

  k8s_version       = "v1.36.1+k3s1"
  spine_k8s_version = "v1.36.1+k3s1" # must equal module.spine.k8s_version in a real consumer

  registration_address      = "10.0.1.5"                    # module.spine.registration_address
  agent_token_ssm_parameter = "/kube-node/demo/agent-token" # module.spine.agent_token_ssm_parameter
  cluster_security_group_id = "sg-0123456789abcdef0"        # module.spine.cluster_security_group_id

  subnet_id = "subnet-0123456789abcdef1" # this pool's AZ — pools are one-subnet-one-AZ

  # Optional: registry mirror, trusted CA, extra node labels beyond the automatic AZ label.
  # registry_mirror_url = "https://harbor.example.internal"
  # extra_node_labels    = { "workload" = "sql" }
}

output "pool_availability_zone" {
  value = module.worker_pool.availability_zone
}
