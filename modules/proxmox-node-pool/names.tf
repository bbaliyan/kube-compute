# SPDX-License-Identifier: Apache-2.0

locals {
  # {number} is 01 for the first worker, as on AWS. The VM name, the Kubernetes node name
  # and the worker_node_refs key all come from here.
  worker_names = {
    for i in range(var.desired_count) : tostring(i) => (
      var.node_name_template == null
      ? "${var.cluster_name}-${var.pool_name}-${i}"
      : replace(var.node_name_template, "{number}", format("%02d", i + 1))
    )
  }
}
