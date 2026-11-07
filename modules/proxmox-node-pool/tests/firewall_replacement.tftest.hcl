# SPDX-License-Identifier: Apache-2.0
# Each worker's firewall options and rules follow that worker VM alone. A mock
# provider generates computed values again on every plan, so an assertion
# cannot tell a replacement from an in-place update; `tofu test -verbose` shows
# the planned actions. These runs check what a mock can show: the firewall keys
# match the worker keys, and an in-place change, a replacement of one worker
# and a smaller pool all apply cleanly. The replaced worker gets a new id, as
# a real VM does.
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
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
  cluster_name         = "bharat"
  proxmox_node         = "pve"
  vm_cores             = 2
  vm_memory_mb         = 4096
  vm_disk_gb           = 30
  desired_count        = 2
  registration_address = "192.168.1.5"
  cluster_agent_token  = "agent-secret-abc123"
  os_image_url         = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name   = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "create" {
  assert {
    condition     = keys(proxmox_virtual_environment_firewall_options.worker) == keys(proxmox_virtual_environment_vm.worker)
    error_message = "the firewall options must use the same keys as the worker VMs"
  }
  assert {
    condition     = keys(proxmox_virtual_environment_firewall_rules.worker) == keys(proxmox_virtual_environment_vm.worker)
    error_message = "the firewall rules must use the same keys as the worker VMs"
  }
}

run "memory_change_applies_in_place" {
  variables {
    vm_memory_mb = 8192
  }

  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.memory[0].dedicated == 8192])
    error_message = "the memory change must reach every worker"
  }
}

run "replacing_one_worker_moves_only_its_firewall" {
  variables {
    vm_memory_mb = 8192
  }
  plan_options {
    replace = [proxmox_virtual_environment_vm.worker["1"]]
  }
  override_resource {
    target = proxmox_virtual_environment_vm.worker["1"]
    values = {
      id             = "worker-1-replaced"
      vm_id          = 201
      ipv4_addresses = [["192.168.1.21", "127.0.0.1"]]
    }
  }

  assert {
    condition     = proxmox_virtual_environment_firewall_options.worker["0"].vm_id == 200 && proxmox_virtual_environment_firewall_rules.worker["0"].vm_id == 200
    error_message = "the firewall of worker 0 must stay on worker 0"
  }
  assert {
    condition     = proxmox_virtual_environment_firewall_options.worker["1"].vm_id == 201 && proxmox_virtual_environment_firewall_rules.worker["1"].vm_id == 201
    error_message = "the firewall of worker 1 must follow its new VM"
  }
}

run "smaller_pool_drops_only_the_removed_firewall" {
  variables {
    vm_memory_mb  = 8192
    desired_count = 1
  }

  assert {
    condition     = keys(proxmox_virtual_environment_firewall_options.worker) == ["0"] && keys(proxmox_virtual_environment_firewall_rules.worker) == ["0"]
    error_message = "a smaller pool must keep only the firewall of the remaining worker"
  }
}
