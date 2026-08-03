# SPDX-License-Identifier: Apache-2.0
# Read-only AWS lookups. No resource blocks belong in this file, ever.

data "aws_caller_identity" "current" {}

# Named-VPC lookup — only consulted when vpc_id isn't given directly.
# Mirrors aws-control-plane's own data.aws_vpc.named lookup.
data "aws_vpc" "named" {
  count = var.vpc_id == null ? 1 : 0
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}
