# region.hcl — sets the provider region for every cluster under this region subtree.
# See eu-west-1/region.hcl for the full doc comment; identical shape, different region.

locals {
  aws_region = "us-east-1"
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
