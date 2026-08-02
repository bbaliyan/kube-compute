# SPDX-License-Identifier: Apache-2.0

output "orchestrator_playbook_path" {
  description = "Absolute path to the cross-node orchestrator playbook. Run it with -e \"$(tofu output -raw orchestrator_extra_vars_json)\". Must be absolute, not path.module-relative: for a Terragrunt-sourced module, path.module is \".\" relative to the module's own working directory (a .terragrunt-cache copy) — a bare relative string is meaningless to a caller running ansible-playbook from a different directory (e.g. the terragrunt unit's own directory, where the operator actually invokes this from)."
  value       = abspath("${path.module}/ansible/upgrade-os.yml")
}

output "orchestrator_extra_vars_json" {
  description = "JSON-encoded extra-vars for orchestrator_playbook_path: the node refs plus SSH connection facts and per-role RKE2 service names."
  value       = jsonencode(local.extra_vars)
}
