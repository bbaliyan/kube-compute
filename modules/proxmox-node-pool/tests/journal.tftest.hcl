# SPDX-License-Identifier: Apache-2.0
# The cloud-init snippet turns on a persistent journal.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/example.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 2
  vm_memory_mb           = 4096
  vm_disk_gb             = 30
  desired_count          = 2
  registration_address   = "192.168.1.5"
  cluster_agent_token    = "agent-secret-abc123"
  proxmox_template_vm_id = 9000
}

run "journal_is_persistent" {
  command = plan

  assert {
    condition = alltrue([
      strcontains(proxmox_virtual_environment_file.vendor_data.source_raw[0].data, "/etc/systemd/journald.conf.d/10-persistent.conf"),
      strcontains(proxmox_virtual_environment_file.vendor_data.source_raw[0].data, "Storage=persistent"),
      strcontains(proxmox_virtual_environment_file.vendor_data.source_raw[0].data, "systemctl restart systemd-journald"),
      strcontains(proxmox_virtual_environment_file.vendor_data.source_raw[0].data, "journalctl --flush"),
    ])
    error_message = "the cloud-init snippet must turn on a persistent journal, restart journald and flush it"
  }
}
