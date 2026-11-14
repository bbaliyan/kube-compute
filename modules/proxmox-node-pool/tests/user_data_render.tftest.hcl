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
}

run "user_data_is_unchanged" {
  command = plan

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "3b3636327b8ab052bfdb7b76230509d96349ef1949d87b4214dc9bd720c435d8"
    error_message = "the first worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "8a77e10736855f6a47d9325ce50efc1b9f0e5fb46cbc19959c9ea24e9410cf98"
    error_message = "the second worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }
}

