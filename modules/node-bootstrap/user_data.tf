# SPDX-License-Identifier: Apache-2.0
# The final user data a provider hands to the node: the cloud-config alone, or a
# MIME multipart/mixed document when shell-script parts run before it. cloud-init
# runs shell-script parts ahead of the cloud-config's own runcmd, so they finish
# before RKE2 is installed. Joining parts by MIME, rather than merging them into
# the YAML, keeps the cloud-config untouched.
locals {
  mime_boundary = "MIMEBOUNDARY"

  # AlmaLinux AMIs likely ship SSM Agent but do not always start it. SSM is the
  # operator's access path to an AWS node, not only a bootstrap transport.
  ssm_agent_script = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  ssm_agent_part = join("\n", [
    "--${local.mime_boundary}",
    "Content-Type: text/x-shellscript; charset=\"us-ascii\"",
    "",
    local.ssm_agent_script,
  ])

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

  shell_parts = concat(var.ssm_agent_enabled ? [local.ssm_agent_part] : [], local.boot_script_parts)

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
