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
  cluster_name = "demo"
}

# Single-node cluster: control_plane_count defaults to 1, cluster_type defaults to
# all_in_one (control-plane node stays schedulable) — no HA-specific inputs needed.
inputs = {
  cluster_name  = local.cluster_name
  aws_region    = include.region.locals.aws_region
  instance_type = "m7g.large"

  allowed_ingress_cidrs = ["10.0.0.0/8"]

  # Placeholder subnet — a real consumer points this at their own private subnet.
  subnet_id = "subnet-0123456789abcdef0"
}
