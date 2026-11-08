# SPDX-License-Identifier: Apache-2.0
# Pins the rendered user data of every worker to a known hash, so a refactor of
# how it is built cannot change what a node boots with.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/demo.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name           = "demo"
  pool_name              = "workers"
  proxmox_node           = "pve"
  vm_cores               = 2
  vm_memory_mb           = 4096
  vm_disk_gb             = 30
  desired_count          = 2
  cluster_agent_token    = "agent-token-for-the-render-test"
  cluster_domain         = "example.test"
  dns_server_address     = "192.168.1.53"
  tsig_key_name          = "kube-compute"
  tsig_key_secret        = "ZmFrZXNlY3JldA=="
  proxmox_template_vm_id = 9000
  boot_scripts           = ["echo one", "echo two"]
}

run "user_data_is_unchanged" {
  command = plan

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "defd5e7bcb91cb436e06826cbcb244e36322eb0c9dfc2b9fbe404e4d6e90ac93"
    error_message = "the first worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "b9b42ba541179810f08eebe0697bb1f048bbb2ff9af9623de320fc4ccf61553b"
    error_message = "the second worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }
}

run "user_data_without_boot_scripts_is_unchanged" {
  command = plan

  variables {
    boot_scripts = []
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "afee52b859395632ab0b0619c9857a973f13ee2bc8b170658652c54872ca3f9d"
    error_message = "the first worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }
}
