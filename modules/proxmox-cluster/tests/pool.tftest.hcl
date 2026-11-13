# SPDX-License-Identifier: Apache-2.0
# The cluster-wide pool_id reaches the control plane and every node
# pool. A node_pools entry may override it. Unset changes nothing.
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

# apply, not plan: the pools read the control plane's token, unknown at plan time.
run "unset_means_no_pool" {
  command = apply

  assert {
    condition     = output.pool_id == null
    error_message = "unset pool_id must reach the control plane as null"
  }
  assert {
    condition     = output.node_pools["inherit"].pool_id == null
    error_message = "unset pool_id must reach the node pools as null"
  }
}

run "cluster_wide_values_reach_control_plane_and_pools" {
  command = apply
  variables {
    pool_id = "kube"
  }

  assert {
    condition     = output.pool_id == "kube"
    error_message = "pool_id must pass through to the control plane"
  }
  assert {
    condition     = output.node_pools["inherit"].pool_id == "kube"
    error_message = "a pool that sets none must take the cluster-wide value"
  }
  assert {
    condition     = output.node_pools["override"].pool_id == "batch"
    error_message = "a node_pools entry's own pool_id must win over the cluster-wide one"
  }
}
