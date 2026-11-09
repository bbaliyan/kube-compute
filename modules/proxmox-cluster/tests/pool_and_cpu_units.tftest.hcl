# SPDX-License-Identifier: Apache-2.0
# Cluster-wide pool_id and cpu_units reach the control plane and every node
# pool. A node_pools entry may override either. Unset changes nothing.
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
      cpu_units              = 50
    }
  }
}

# apply, not plan: the pools read the control plane's token, unknown at plan time.
run "unset_means_no_pool_and_default_cpu_weight" {
  command = apply

  assert {
    condition     = output.pool_id == null && output.cpu_units == null
    error_message = "unset pool_id and cpu_units must reach the control plane as null"
  }
  assert {
    condition     = output.node_pools["inherit"].pool_id == null && output.node_pools["inherit"].cpu_units == null
    error_message = "unset pool_id and cpu_units must reach the node pools as null"
  }
}

run "cluster_wide_values_reach_control_plane_and_pools" {
  command = apply
  variables {
    pool_id   = "kube"
    cpu_units = 100
  }

  assert {
    condition     = output.pool_id == "kube" && output.cpu_units == 100
    error_message = "pool_id and cpu_units must pass through to the control plane"
  }
  assert {
    condition     = output.node_pools["inherit"].pool_id == "kube" && output.node_pools["inherit"].cpu_units == 100
    error_message = "a pool that sets neither must take the cluster-wide values"
  }
  assert {
    condition     = output.node_pools["override"].pool_id == "batch" && output.node_pools["override"].cpu_units == 50
    error_message = "a node_pools entry's own pool_id and cpu_units must win over the cluster-wide ones"
  }
}
