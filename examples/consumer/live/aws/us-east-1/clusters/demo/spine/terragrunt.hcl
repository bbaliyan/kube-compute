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

# Same cluster_name as eu-west-1/clusters/demo/spine, deliberately — this proves the
# state-backend key (path_relative_to_include(), see common.hcl) does not collide across
# regions: this unit's key is "us-east-1/clusters/demo/spine/terraform.tfstate", the
# other's is "eu-west-1/clusters/demo/spine/terraform.tfstate".
inputs = {
  cluster_name  = local.cluster_name
  aws_region    = include.region.locals.aws_region
  instance_type = "m7g.large"

  allowed_ingress_cidrs = ["10.0.0.0/8"]

  subnet_id = "subnet-0123456789abcdef9"
}
