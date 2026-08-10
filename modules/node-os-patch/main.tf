# SPDX-License-Identifier: Apache-2.0
# Resource-less "data module": renders the orchestrator script but creates
# and runs nothing itself. OS patching is operator-triggered, not a
# desired-state resource — it must never fire just because an unrelated
# `tofu apply` touched this module's inputs. The caller runs the rendered
# script themselves (`bash <(tofu output -raw orchestrator_script)`), on
# whatever schedule they choose.

locals {
  orchestrator_script = templatefile("${path.module}/templates/upgrade-os.sh.tftpl", {
    control_plane_node_refs = var.control_plane_node_refs
    worker_node_refs        = var.worker_node_refs
    ssh_user                = var.ssh_user
    ssh_private_key_file    = var.ssh_private_key_file
    rke2_server_service     = var.rke2_server_service
    rke2_agent_service      = var.rke2_agent_service
  })
}
