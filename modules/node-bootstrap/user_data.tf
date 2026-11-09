# SPDX-License-Identifier: Apache-2.0
# The final user data a provider hands to the node: the cloud-config alone, or a
# MIME multipart/mixed document when shell-script parts run before it. cloud-init
# runs shell-script parts ahead of the cloud-config's own runcmd, so they finish
# before RKE2 is installed. Joining parts by MIME, rather than merging them into
# the YAML, keeps the cloud-config untouched.
locals {
  mime_boundary = "MIMEBOUNDARY"

  boot_script_parts = [
    for script in var.boot_scripts : join("\n", [
      "--${local.mime_boundary}",
      "Content-Type: text/x-shellscript; charset=\"us-ascii\"",
      "",
      "#!/bin/bash",
      "export CLUSTER_NAME='${var.cluster_name}' NODE_ROLE='${var.node_role == "worker" ? "worker" : "control-plane"}' NODE_NAME='${var.node_name}'",
      "script=\"$(mktemp)\"",
      "cat > \"$script\" <<'KUBE_COMPUTE_BOOT_SCRIPT'",
      script,
      "KUBE_COMPUTE_BOOT_SCRIPT",
      "bash \"$script\" </dev/null",
    ])
  ]

  shell_parts = local.boot_script_parts

  # With no shell parts the user data is the plain cloud-config, so a node that
  # was created without boot scripts keeps the user data it booted with.
  user_data = length(local.shell_parts) == 0 ? local.cloud_init_user_data : join("\n", concat(
    [
      "Content-Type: multipart/mixed; boundary=\"${local.mime_boundary}\"",
      "MIME-Version: 1.0",
      "",
    ],
    local.shell_parts,
    [
      "--${local.mime_boundary}",
      "Content-Type: text/cloud-config; charset=\"us-ascii\"",
      "",
      local.cloud_init_user_data,
      "--${local.mime_boundary}--",
      "",
    ],
  ))
}
