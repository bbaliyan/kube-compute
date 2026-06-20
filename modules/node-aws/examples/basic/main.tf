# SPDX-License-Identifier: Apache-2.0
# Minimal node-aws usage. Placeholder values — replace for your environment.
# For `tofu plan` illustration only (no backend wired).
provider "aws" {
  region = "eu-west-1"
}

module "cluster" {
  source = "../.."

  cluster_name          = "demo"
  k8s_version           = "v1.32.5+k3s1"
  aws_region            = "eu-west-1"
  instance_type         = "m7g.large"
  allowed_ingress_cidrs = ["10.0.0.0/8"]

  # Networking: omit subnet_id to use the account's default VPC, or pass your own:
  # subnet_id = "subnet-0123456789abcdef0"

  # DNS (optional): set a domain to get a named FQDN + wildcard. Add hosted_zone_id to
  # have the module create the Route53 wildcard record; otherwise register
  # module.cluster.wildcard_dns_name -> module.cluster.cluster_ip in your own DNS.
  # cluster_domain = "example.internal"
  # hosted_zone_id = "Z0123456789ABCDEFGHIJ"

  # Optional: registry mirror, trusted CA, GitOps.
  # registry_mirror_url      = "https://harbor.example.internal"
  # gitops_platform_repo_url = "https://github.com/me/kube-platform.git"
}

output "register_this_dns" {
  description = "If you did not pass hosted_zone_id, create this wildcard A record pointing at cluster_ip."
  value = {
    name = module.cluster.wildcard_dns_name
    ip   = module.cluster.cluster_ip
  }
}
