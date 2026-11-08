# SPDX-License-Identifier: Apache-2.0
# Genesis and the other control-plane nodes were two VM resources, two snippet
# resources and two module calls. These keep every existing node in place.
# control_plane_count is at most 5.

moved {
  from = proxmox_virtual_environment_vm.control_plane
  to   = proxmox_virtual_environment_vm.control_plane["0"]
}

moved {
  from = proxmox_virtual_environment_file.node_init
  to   = proxmox_virtual_environment_file.node_init["0"]
}

moved {
  from = module.node_bootstrap
  to   = module.node_bootstrap["0"]
}

moved {
  from = proxmox_virtual_environment_vm.control_plane_additional["1"]
  to   = proxmox_virtual_environment_vm.control_plane["1"]
}

moved {
  from = proxmox_virtual_environment_file.node_init_additional["1"]
  to   = proxmox_virtual_environment_file.node_init["1"]
}

moved {
  from = module.node_bootstrap_additional["1"]
  to   = module.node_bootstrap["1"]
}

moved {
  from = proxmox_virtual_environment_vm.control_plane_additional["2"]
  to   = proxmox_virtual_environment_vm.control_plane["2"]
}

moved {
  from = proxmox_virtual_environment_file.node_init_additional["2"]
  to   = proxmox_virtual_environment_file.node_init["2"]
}

moved {
  from = module.node_bootstrap_additional["2"]
  to   = module.node_bootstrap["2"]
}

moved {
  from = proxmox_virtual_environment_vm.control_plane_additional["3"]
  to   = proxmox_virtual_environment_vm.control_plane["3"]
}

moved {
  from = proxmox_virtual_environment_file.node_init_additional["3"]
  to   = proxmox_virtual_environment_file.node_init["3"]
}

moved {
  from = module.node_bootstrap_additional["3"]
  to   = module.node_bootstrap["3"]
}

moved {
  from = proxmox_virtual_environment_vm.control_plane_additional["4"]
  to   = proxmox_virtual_environment_vm.control_plane["4"]
}

moved {
  from = proxmox_virtual_environment_file.node_init_additional["4"]
  to   = proxmox_virtual_environment_file.node_init["4"]
}

moved {
  from = module.node_bootstrap_additional["4"]
  to   = module.node_bootstrap["4"]
}
