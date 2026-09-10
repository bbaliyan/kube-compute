# SPDX-License-Identifier: Apache-2.0
# Deliberately not named "current". A consumer's terragrunt generate blocks land
# .tf files in this same module directory, and "current" is the name anyone would
# pick for this -- kube-clusters' own iam-eso include already uses it, and two
# declarations of one name is a hard init failure for every cluster.
data "aws_caller_identity" "kube_compute" {}

data "aws_ec2_instance_type" "autoscaler_worker" {
  for_each      = local.autoscaler_groups
  instance_type = each.value.instance_type
}

# One image name, two architectures: the architecture filter is what stops an
# arm64 group adopting the x86_64 build and vice versa.
data "aws_ami" "autoscaler_worker" {
  for_each = {
    for name, g in local.autoscaler_groups : name => g
    if g.os_image_ami_id == null && var.os_image_name != null
  }

  most_recent = true
  owners      = ["self"]
  filter {
    name   = "name"
    values = [var.os_image_name]
  }
  filter {
    name   = "architecture"
    values = [local.autoscaler_group_arch[each.key]]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}
