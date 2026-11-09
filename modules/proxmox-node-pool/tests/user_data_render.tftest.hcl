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
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "cc34940c6145291388b082c3a359a09d7ca967d82d51fa39f77a7af36b8bd5a3"
    error_message = "the first worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "1d3a182a8e50a3f6d713998ad1f1d34049758eba70bea3704fc58c3ac9a2f322"
    error_message = "the second worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }
}

run "user_data_without_boot_scripts_is_unchanged" {
  command = plan

  variables {
    boot_scripts = []
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "b29e802d6495c1f4540b92bf98d7a9a1867151feff21c8c4cd9f9b200b03bfd7"
    error_message = "the first worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }
}
