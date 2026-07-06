# SPDX-License-Identifier: Apache-2.0
# Minimal spine-aws usage. Placeholder values — replace for your environment.
# For `tofu plan` illustration only (no backend wired).
provider "aws" {
  region = "eu-west-1"
}

module "spine" {
  source = "../.."

  cluster_name          = "demo"
  k8s_version           = "v1.36.1+k3s1"
  aws_region            = "eu-west-1"
  instance_type         = "m7g.large"
  allowed_ingress_cidrs = ["10.0.0.0/8"]

  # Networking: omit both to use the account's default VPC, or pass one of:
  # subnet_id   = "subnet-0123456789abcdef0"   # literal ID
  # subnet_name = "my-private-subnet-az1"      # Name tag (add vpc_name to scope by VPC)

  # DNS (optional): set a domain to get a named FQDN + wildcard. Add hosted_zone_id to
  # have the module create the Route53 wildcard record; otherwise register
  # module.spine.wildcard_dns_name -> module.spine.cluster_ip in your own DNS.
  # cluster_domain = "example.internal"
  # hosted_zone_id = "Z0123456789ABCDEFGHIJ"

  # Optional: registry mirror, trusted CA, GitOps.
  # registry_mirror_url      = "https://harbor.example.internal"
  # gitops_platform_repo_url = "https://github.com/me/kube-platform.git"

  # High availability (optional): 3 or 5 control-plane nodes, one per AZ, behind an internal
  # NLB. control_plane_subnets must span at least 3 distinct AZs; the single subnet_id/subnet_name
  # above is not used for control-plane placement or networking once control_plane_count > 1 —
  # control_plane_subnets is the sole source of both the instances' subnets and the module's VPC
  # in that mode.
  # control_plane_count = 3
  # control_plane_subnets = {
  #   "eu-west-1a" = "subnet-0123456789abcdef0"
  #   "eu-west-1b" = "subnet-0123456789abcdef1"
  #   "eu-west-1c" = "subnet-0123456789abcdef2"
  # }

  # Durability (optional): etcd snapshots default on for control_plane_count > 1. Add an S3
  # bucket to also upload them off-node (grants the control-plane IAM role scoped access to it).
  # etcd_snapshot_s3_bucket = "my-cluster-etcd-snapshots"

  # Registration endpoint mode (optional, only relevant with control_plane_count > 1): defaults
  # to an internal NLB. "dns" is cheaper (Route53 multivalue + health checks) but TTL-bound
  # failover; requires cluster_domain + hosted_zone_id/hosted_zone_name above. "static" brings
  # your own address and creates neither an LB nor a DNS record.
  # endpoint_mode = "dns"
  # endpoint_mode = "static"
  # static_registration_address = "my-own-lb.internal.example.com"
}

output "register_this_dns" {
  description = "If you did not pass hosted_zone_id, create this wildcard A record pointing at cluster_ip."
  value = {
    name = module.spine.wildcard_dns_name
    ip   = module.spine.cluster_ip
  }
}
