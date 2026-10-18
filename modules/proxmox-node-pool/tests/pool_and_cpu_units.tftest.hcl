# SPDX-License-Identifier: Apache-2.0
# pool_id and cpu_units are optional. Unset must leave the VMs in no Proxmox
# pool and on the provider's default CPU weight, as before they existed.
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

run "unset_means_no_pool_and_default_cpu_weight" {
  command = plan

  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.pool_id == null])
    error_message = "workers must not join a pool when pool_id is unset"
  }
  # The mock reports a computed units as 0, so unset is checked on the output
  # that carries the input, not on the VM attribute.
  assert {
    condition     = output.cpu_units == null
    error_message = "cpu_units must stay null so the provider keeps its default CPU weight"
  }
}

run "set_applies_to_every_worker" {
  command = plan
  variables {
    pool_id   = "kube"
    cpu_units = 100
  }

  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.pool_id == "kube"])
    error_message = "every worker must join the pool named by pool_id"
  }
  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.worker : vm.cpu[0].units == 100])
    error_message = "every worker must carry cpu_units as its CPU weight"
  }
}
