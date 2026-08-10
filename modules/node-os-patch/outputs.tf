# SPDX-License-Identifier: Apache-2.0

output "orchestrator_script" {
  description = "Rendered OS-patch orchestrator: a self-contained bash script (plain SSH, no Ansible) that patches control-plane nodes one at a time, then worker nodes one at a time. Run with `bash <(tofu output -raw orchestrator_script)`."
  value       = local.orchestrator_script
}
