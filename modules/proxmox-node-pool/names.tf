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

  mime_boundary = "MIMEBOUNDARY"

  # cloud-init runs shell-script parts ahead of the cloud-config's own runcmd, so these
  # finish before RKE2 is installed. With no scripts the snippet is the plain cloud-config
  # it always was, and no VM is replaced.
  boot_script_parts = {
    for k, name in local.worker_names : k => [
      for script in var.boot_scripts : join("\n", [
        "--${local.mime_boundary}",
        "Content-Type: text/x-shellscript; charset=\"us-ascii\"",
        "",
        "#!/bin/bash",
        "export CLUSTER_NAME='${var.cluster_name}' NODE_ROLE='worker' NODE_NAME='${name}'",
        "script=\"$(mktemp)\"",
        "cat > \"$script\" <<'KUBE_COMPUTE_BOOT_SCRIPT'",
        script,
        "KUBE_COMPUTE_BOOT_SCRIPT",
        "bash \"$script\" </dev/null",
      ])
    ]
  }

  node_init_data = {
    for k, m in module.node_bootstrap : k => length(var.boot_scripts) == 0 ? m.cloud_init_user_data : join("\n", concat([
      "Content-Type: multipart/mixed; boundary=\"${local.mime_boundary}\"",
      "MIME-Version: 1.0",
      "",
      ], local.boot_script_parts[k], [
      "--${local.mime_boundary}",
      "Content-Type: text/cloud-config; charset=\"us-ascii\"",
      "",
      m.cloud_init_user_data,
      "--${local.mime_boundary}--",
      "",
    ]))
  }
}
