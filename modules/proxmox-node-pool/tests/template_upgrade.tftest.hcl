# SPDX-License-Identifier: Apache-2.0
# A new proxmox_template_vm_id reaches only new workers and workers replaced on
# purpose, so one apply never rebuilds the whole pool.
#
# The runs check the clone source that each VM keeps in state. A mock provider
# cannot show more: it does not prove that the real provider plans no
# replacement, or that a replaced worker joins the cluster again.
# `tofu test -verbose` shows the planned actions.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name           = "bharat"
  proxmox_node           = "pve"
  vm_cores               = 2
  vm_memory_mb           = 4096
  vm_disk_gb             = 30
  desired_count          = 2
  registration_address   = "192.168.1.5"
  cluster_agent_token    = "agent-secret-abc123"
  proxmox_template_vm_id = 9000
}

run "workers_are_created_from_the_template" {
  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.clone[0].vm_id == 9000])
    error_message = "new workers must be cloned from the configured template"
  }
}

run "new_template_keeps_the_existing_workers" {
  variables {
    proxmox_template_vm_id = 9001
  }

  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.clone[0].vm_id == 9000])
    error_message = "a new template must not replace the existing workers: one apply would rebuild the pool"
  }
}

run "replacing_one_worker_moves_only_that_worker" {
  variables {
    proxmox_template_vm_id = 9001
  }
  plan_options {
    replace = [proxmox_virtual_environment_vm.worker["1"]]
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["1"].clone[0].vm_id == 9001
    error_message = "the replaced worker must be cloned from the new template"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.worker["0"].clone[0].vm_id == 9000
    error_message = "a worker that was not replaced must keep its template"
  }
}

run "a_larger_pool_clones_new_workers_from_the_new_template" {
  variables {
    proxmox_template_vm_id = 9002
    desired_count          = 3
  }

  assert {
    condition     = proxmox_virtual_environment_vm.worker["2"].clone[0].vm_id == 9002
    error_message = "a new worker must be cloned from the configured template"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.worker["0"].clone[0].vm_id == 9000 && proxmox_virtual_environment_vm.worker["1"].clone[0].vm_id == 9001
    error_message = "existing workers must keep their templates when the pool grows"
  }
}
