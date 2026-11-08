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
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "69dde695d04a850e33a8d5a0b7dac4635f81bf44398a9284df9649736473aa7e"
    error_message = "the first worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "00285e494dea3aa2e25d5187b0ed8a0e78a291676016319043022f0340bf2f56"
    error_message = "the second worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }
}

run "user_data_without_boot_scripts_is_unchanged" {
  command = plan

  variables {
    boot_scripts = []
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "24b6222538392238cf50713a2043ccb7998fbd81dee8bde2e240f9a2bbc49b7d"
    error_message = "the first worker user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }
}
