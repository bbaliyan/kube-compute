# SPDX-License-Identifier: Apache-2.0
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}
mock_provider "dns" {}

variables {
  cluster_name          = "bharat"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  os_image_url          = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name    = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "no_pools_creates_only_control_plane" {
  command = plan

  assert {
    condition     = length(module.node_pools) == 0
    error_message = "empty node_pools map must create zero worker-pool module instances"
  }
}

run "one_pool_creates_its_workers_and_shares_the_agent_token" {
  # apply (not plan): the pool's cluster_agent_token input reads
  # module.control_plane's random_password output, which is unknown at
  # plan time — matches the precedent in proxmox-control-plane's own
  # topology.tftest.hcl (its "ha_control_plane_creates..." run).
  command = apply

  variables {
    node_pools = {
      pool-a = {
        proxmox_node         = "pve"
        vm_cores             = 1
        vm_memory_mb         = 4096
        vm_disk_gb           = 40
        os_image_url         = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
        os_image_file_name   = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
        desired_count        = 2
        registration_address = "192.168.1.5"
      }
    }
  }

  assert {
    condition     = length(module.node_pools) == 1
    error_message = "one node_pools entry must create exactly one worker-pool module instance"
  }

  assert {
    condition     = length(module.node_pools["pool-a"].worker_node_refs) == 2
    error_message = "desired_count = 2 in the pool-a object must create 2 worker VMs"
  }

  assert {
    condition     = output.cluster_agent_token == module.control_plane.cluster_agent_token
    error_message = "the module's own cluster_agent_token output must equal control_plane's, proving the same-state wiring (not a separate/mismatched token)"
  }
}
