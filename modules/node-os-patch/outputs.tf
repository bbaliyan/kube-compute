# SPDX-License-Identifier: Apache-2.0

output "orchestrator_script" {
  description = "Rendered OS-patch orchestrator: a self-contained bash script (plain SSH, no Ansible) that patches every control-plane node one at a time, then every worker node one at a time. Run with `bash <(tofu output -raw orchestrator_script)`."
  value       = local.orchestrator_script
}
