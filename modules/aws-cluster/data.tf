# SPDX-License-Identifier: Apache-2.0
# Deliberately not named "current". A consumer's terragrunt generate blocks land
# .tf files in this same module directory, and "current" is the name anyone would
# pick for this -- kube-clusters' own iam-eso include already uses it, and two
# declarations of one name is a hard init failure for every cluster.
data "aws_caller_identity" "kube_compute" {}
