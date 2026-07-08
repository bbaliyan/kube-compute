# SPDX-License-Identifier: Apache-2.0
# Renders cloud-init in the worker role so the agent-join path can be
# validated offline (YAML + embedded bash), alongside the server-init render
# in ../render-check. Not for production use.
module "bootstrap" {
  source = "../../.."

  cloud_init_template       = "${path.module}/../../../templates/cloud-init-al2023.yaml.tpl"
  cluster_name              = "render-check-worker"
  k8s_version               = "v1.36.1+k3s1"
  node_role                 = "worker"
  registration_address      = "10.0.1.5"
  agent_token_fetch_command = "aws ssm get-parameter --name /kube-compute/render-check/agent-token --with-decryption --query Parameter.Value --output text --region eu-west-1"
  node_labels               = { "topology.kubernetes.io/zone" = "eu-west-1a" }
}

output "cloud_init" {
  value     = module.bootstrap.cloud_init
  sensitive = true
}
