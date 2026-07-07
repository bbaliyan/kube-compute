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

locals {
  cluster_name = "demo-ha"
  k8s_version  = "v1.36.1+k3s1"
}

# HA control plane: one node per AZ across 3 AZs, dedicated_control_plane so the
# control-plane nodes are tainted and only the two worker pools below run workloads.
inputs = {
  cluster_name  = local.cluster_name
  aws_region    = include.region.locals.aws_region
  instance_type = "m7g.large"
  k8s_version   = local.k8s_version
  cluster_type  = "dedicated_control_plane"

  allowed_ingress_cidrs = ["10.0.0.0/8"]

  control_plane_count = 3
  control_plane_subnets = {
    "eu-west-1a" = "subnet-0123456789abcdefa"
    "eu-west-1b" = "subnet-0123456789abcdefb"
    "eu-west-1c" = "subnet-0123456789abcdefc"
  }
}
