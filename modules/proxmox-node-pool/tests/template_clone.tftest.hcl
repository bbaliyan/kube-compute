# SPDX-License-Identifier: Apache-2.0
# Guards the kube-images template-clone path for worker pools: always a FULL
# clone, no stock-image import alongside it.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/example.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name         = "example"
  proxmox_node         = "pve"
  vm_cores             = 2
  vm_memory_mb         = 4096
  vm_disk_gb           = 30
  desired_count        = 2
  registration_address = "192.168.1.5"
  cluster_agent_token  = "agent-secret-abc123"
}

run "template_clone_is_always_a_full_clone" {
  command = plan
  variables {
    proxmox_template_vm_id = 9000
  }

  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : length(vm.clone) == 1
    ])
    error_message = "a supplied proxmox_template_vm_id must produce exactly one clone block per worker"
  }
  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : vm.clone[0].full == true
    ])
    error_message = "full must be true on every clone — a linked clone makes every worker permanently depend on the kube-images template, which breaks the moment prune-images.sh deletes it"
  }
  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : vm.clone[0].vm_id == 9000
    ])
    error_message = "every worker's clone block must reference the supplied template VM ID"
  }
  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : vm.disk[0].import_from == null
    ])
    error_message = "a cloned worker must not also import a stock image"
  }
}
