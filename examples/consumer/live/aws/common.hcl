# common.hcl — shared Terragrunt config for every region/cluster under this tree.
#
# Included by each cluster unit via:
#
#   include "common" {
#     path   = find_in_parent_folders("common.hcl")
#     expose = true
#   }
#
# Exposes:
#   include.common.locals.state_bucket — S3 bucket name for Terraform state (placeholder)
#   include.common.locals.state_region — region the state bucket itself lives in

locals {
  # Placeholder — a real consumer points this at their own pre-created bucket.
  state_bucket = "example-org-tofu-state"
  state_region = "eu-west-1"
}

# ── Module source ─────────────────────────────────────────────────────────────
# Pinned to a commit; bump deliberately (and re-apply each cluster) to pick up module
# changes. A cluster unit can still override `source` if it needs to pin differently.
terraform {
  source = "git::https://github.com/bbaliyan/kube-node.git//modules/spine-aws?ref=0e2723028b30a8d10b3e4d7bfcc732f846465b89"
}

# ── Remote state ─────────────────────────────────────────────────────────────
# Native OpenTofu S3 locking (use_lockfile = true) — no DynamoDB table needed. The key
# is derived from each unit's own path (path_relative_to_include()), which already
# includes the region and cluster name as path segments — this is what makes two
# same-named clusters in different regions land at different state keys with zero extra
# logic (see the region.hcl in each region for the region-scoping half of this).
remote_state {
  backend = "s3"

  config = {
    bucket       = local.state_bucket
    region       = local.state_region
    key          = "${path_relative_to_include()}/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
