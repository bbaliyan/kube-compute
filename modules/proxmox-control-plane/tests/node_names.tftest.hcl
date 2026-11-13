# SPDX-License-Identifier: Apache-2.0
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/app-red.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name               = "app-red"
  proxmox_node               = "pve"
  vm_cores                   = 4
  vm_memory_mb               = 8192
  vm_disk_gb                 = 50
  control_plane_count        = 3
  control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
  cluster_domain             = "red.lan"
  cluster_network_cidr       = "192.168.1.0/24"
  vm_gateway                 = "192.168.1.1"
  allowed_ingress_cidrs      = ["192.168.1.0/24"]
  proxmox_template_vm_id     = 9000
  dns_server_address         = "192.168.1.53"
  tsig_key_name              = "kube-compute"
  tsig_key_secret            = "ZmFrZXNlY3JldA=="
}

run "unset_template_keeps_the_names" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].name == "app-red-cp-0"
    error_message = "unset, the first VM must keep its name: got ${proxmox_virtual_environment_vm.control_plane["0"].name}"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["2"].name == "app-red-cp-2"
    error_message = "unset, the other VMs must keep their names"
  }
  assert {
    condition     = toset(keys(output.control_plane_node_refs)) == toset(["app-red-cp-0", "app-red-cp-1", "app-red-cp-2"])
    error_message = "unset, control_plane_node_refs must keep its keys: got ${jsonencode(keys(output.control_plane_node_refs))}"
  }
}

run "template_names_every_node" {
  command = plan

  variables {
    node_name_template = "cp-red-{number}"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].name == "cp-red-01"
    error_message = "the first VM must take number 01: got ${proxmox_virtual_environment_vm.control_plane["0"].name}"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["2"].name == "cp-red-03"
    error_message = "the third VM must take number 03"
  }
  assert {
    condition     = toset(keys(output.control_plane_node_refs)) == toset(["cp-red-01", "cp-red-02", "cp-red-03"])
    error_message = "control_plane_node_refs must be keyed by the new names: got ${jsonencode(keys(output.control_plane_node_refs))}"
  }
}

run "template_without_number_is_rejected" {
  command = plan

  variables {
    node_name_template = "cp-red"
  }

  expect_failures = [var.node_name_template]
}

run "template_with_invalid_hostname_is_rejected" {
  command = plan

  variables {
    node_name_template = "CP_{number}"
  }

  expect_failures = [var.node_name_template]
}

# The node payloads embed generated tokens, so reading them needs an apply, and an apply
# would otherwise run nsupdate against the test's DNS server.
