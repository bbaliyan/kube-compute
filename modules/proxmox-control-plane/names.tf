# SPDX-License-Identifier: Apache-2.0

locals {
  # {number} is 01 for the first node, as on AWS. The VM name, the Kubernetes node name and
  # the control_plane_node_refs key all come from here.
  control_plane_names = {
    for i in range(var.control_plane_count) : tostring(i) => (
      var.node_name_template == null
      ? "${var.cluster_name}-cp-${i}"
      : replace(var.node_name_template, "{number}", format("%02d", i + 1))
    )
  }

}
