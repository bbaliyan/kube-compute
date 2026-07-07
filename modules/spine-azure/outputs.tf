# SPDX-License-Identifier: Apache-2.0

# NOTE: this file currently holds only the two outputs Task 5's ha_lb.tftest.hcl needs
# (registration_address, control_plane_node_refs). The plan's Task 6 brief defines the
# full standardized output set for this module (cluster_name, instance_id, cluster_ip,
# key_vault_id, etc.) in this same file — Task 6 appends those without redefining the
# two declared here. See task-5-report.md for why these two exist ahead of Task 6.

# ---- Join flow: consumed by worker-pool-azure ----
output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API: null for control_plane_count = 1 (ADR 0003 — no endpoint at all), the internal Standard LB's frontend private IP otherwise."
  value       = local.registration_address
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, provider}."
  value = merge(
    {
      "${var.cluster_name}-cp-0" = {
        instance_id = azurerm_linux_virtual_machine.control_plane.id
        provider    = "azure"
      }
    },
    {
      for k, vm in azurerm_linux_virtual_machine.control_plane_additional :
      "${var.cluster_name}-cp-${k}" => {
        instance_id = vm.id
        provider    = "azure"
      }
    }
  )
}
