# SPDX-License-Identifier: Apache-2.0

# Not named "current": see the note in aws-cluster/data.tf.
data "aws_caller_identity" "pod_identity" {}
