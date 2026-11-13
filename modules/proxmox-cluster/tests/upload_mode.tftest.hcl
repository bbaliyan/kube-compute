# SPDX-License-Identifier: Apache-2.0
# The cluster-wide cloud_init_upload_mode reaches the control plane and every
# node pool. Unset changes nothing.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/example.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  cluster_network_cidr   = "192.168.1.0/24"
  proxmox_template_vm_id = 9000
  node_pools = {
    inherit = {
      proxmox_node         = "pve"
      vm_cores             = 1
      vm_memory_mb         = 4096
      vm_disk_gb           = 40
      desired_count        = 1
      registration_address = "192.168.1.5"
    }
    override = {
      proxmox_node           = "pve"
      vm_cores               = 1
      vm_memory_mb           = 4096
      vm_disk_gb             = 40
      proxmox_template_vm_id = 9000
      desired_count          = 1
      registration_address   = "192.168.1.5"
      pool_id                = "batch"
    }
  }
}

run "unset_means_the_provider_default" {
  command = apply

  assert {
    condition     = output.cloud_init_upload_mode == null
    error_message = "unset must reach the control plane as null"
  }
  assert {
    condition     = alltrue([for name, p in output.node_pools : p.cloud_init_upload_mode == null])
    error_message = "unset must reach every node pool as null"
  }
}

run "sftp_reaches_control_plane_and_every_pool" {
  command = apply
  variables {
    cloud_init_upload_mode = "sftp"
  }

  assert {
    condition     = output.cloud_init_upload_mode == "sftp"
    error_message = "sftp must reach the control plane"
  }
  assert {
    condition     = alltrue([for name, p in output.node_pools : p.cloud_init_upload_mode == "sftp"])
    error_message = "sftp must reach every node pool, including one that overrides pool_id"
  }
}

run "a_bad_value_is_rejected" {
  command = plan
  variables {
    cloud_init_upload_mode = "scp"
  }

  expect_failures = [var.cloud_init_upload_mode]
}
