# SPDX-License-Identifier: Apache-2.0
# pool_id are optional. Unset must leave the VMs in no Proxmox
# pool, as before it existed.
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
  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 2
  vm_memory_mb           = 4096
  vm_disk_gb             = 30
  desired_count          = 2
  registration_address   = "192.168.1.5"
  cluster_agent_token    = "agent-secret-abc123"
  proxmox_template_vm_id = 9000
}

run "unset_means_no_pool" {
  command = plan

  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.pool_id == null])
    error_message = "workers must not join a pool when pool_id is unset"
  }
}

run "set_applies_to_every_worker" {
  command = plan
  variables {
    pool_id = "kube"
  }

  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.pool_id == "kube"])
    error_message = "every worker must join the pool named by pool_id"
  }
}
