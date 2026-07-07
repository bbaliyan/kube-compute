# region.hcl — sets the provider region for every cluster under this region subtree.
#
# Included by each cluster unit via:
#
#   include "region" {
#     path   = find_in_parent_folders("region.hcl")
#     expose = true
#   }
#
# Exposes:
#   include.region.locals.aws_region — region string, e.g. for cluster_name/AZ math

locals {
  aws_region = "eu-west-1"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOT
    provider "aws" {
      region = "${local.aws_region}"
    }
  EOT
}
