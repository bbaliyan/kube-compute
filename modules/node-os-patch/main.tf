# SPDX-License-Identifier: Apache-2.0
# Resource-less "data module" (like ../component-versions): computes the
# orchestrator playbook's path and extra-vars, but creates nothing and runs
# nothing itself. OS patching is an operator-triggered action, not a
# desired-state resource — it must never fire just because an unrelated
# `tofu apply` touched this module's inputs, the way node-bootstrap's own
# null_resource does for one-time provisioning. The caller runs
# `ansible-playbook <orchestrator_playbook_path> -e <orchestrator_extra_vars_json>`
# themselves, on whatever schedule they choose.

locals {
  extra_vars = {
    control_plane_node_refs      = var.control_plane_node_refs
    worker_node_refs             = var.worker_node_refs
    ansible_ssh_user             = var.ansible_ssh_user
    ansible_ssh_private_key_file = var.ansible_ssh_private_key_file
    rke2_server_service          = var.rke2_server_service
    rke2_agent_service           = var.rke2_agent_service
  }
}
