# SPDX-License-Identifier: Apache-2.0

output "orchestrator_playbook_path" {
  description = "Path to the cross-node orchestrator playbook. Run it with -e \"$(tofu output -raw orchestrator_extra_vars_json)\"."
  value       = "${path.module}/ansible/upgrade-os.yml"
}

output "orchestrator_extra_vars_json" {
  description = "JSON-encoded extra-vars for orchestrator_playbook_path: the node refs plus SSH connection facts and per-role RKE2 service names."
  value       = jsonencode(local.extra_vars)
}
