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

run "platform_pool_takes_the_platform_ingress_and_the_wildcard_record" {
  command = plan

  variables {
    cluster_domain       = "lan"
    dns_server_address   = "192.168.1.53"
    tsig_key_name        = "kube-compute"
    tsig_key_secret      = "ZmFrZXNlY3JldA=="
    cluster_network_cidr = "192.168.1.0/24"
    platform_node_group  = "platform"
    node_pools = {
      platform = {
        proxmox_node       = "pve"
        vm_cores           = 4
        vm_memory_mb       = 16384
        vm_disk_gb         = 40
        os_image_url       = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
        os_image_file_name = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
        desired_count      = 1
      }
      workers = {
        proxmox_node       = "pve"
        vm_cores           = 4
        vm_memory_mb       = 8192
        vm_disk_gb         = 40
        os_image_url       = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
        os_image_file_name = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
        desired_count      = 2
        node_taints        = ["dedicated=batch:NoSchedule"]
      }
    }
  }

  assert {
    condition     = local.platform_helm_values_object.platformNodeSelector["kube-compute.io/node-group"] == "platform"
    error_message = "the platform Application must pin its components to the platform pool's node-group label"
  }
  assert {
    condition = (
      module.control_plane.wildcard_registration_enabled == false &&
      module.node_pools["platform"].wildcard_dns_registration_enabled == true &&
      module.node_pools["workers"].wildcard_dns_registration_enabled == false
    )
    error_message = "the wildcard record must be published by the platform pool alone, with DNS settings inherited from the cluster"
  }
  assert {
    condition     = jsonencode(local.control_plane_ingress_ports) == jsonencode([6443]) && jsonencode(local.platform_ingress_ports) == jsonencode([80, 443])
    error_message = "the platform pool must take the ingress ports, leaving the control plane only the Kubernetes API"
  }
  assert {
    condition     = toset(keys(module.node_pools["workers"].worker_node_refs)) == toset(["bharat-workers-0", "bharat-workers-1"])
    error_message = "each pool's workers must be named after the pool, or two pools collide on VM names and snippets"
  }
}

run "platform_node_group_must_name_a_pool" {
  command = plan

  variables {
    platform_node_group = "missing"
  }

  expect_failures = [var.platform_node_group]
}
