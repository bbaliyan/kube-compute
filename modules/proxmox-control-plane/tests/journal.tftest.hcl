# SPDX-License-Identifier: Apache-2.0
# The cloud-init snippet turns on a persistent journal.
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

# An apply would otherwise run nsupdate against the test's DNS server.
override_module {
  target  = module.dns_registration
  outputs = { fqdn = "api.example.example.com.", record_created = true }
}

override_module {
  target  = module.dns_registration_wildcard
  outputs = { fqdn = "*.example.example.com.", record_created = true }
}

variables {
  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  control_plane_count    = 3
  proxmox_template_vm_id = 9000

  cluster_domain       = "example.com"
  cluster_network_cidr = "192.168.1.0/24"
  dns_server_address   = "192.168.1.53"
  tsig_key_name        = "kube-compute"
  tsig_key_secret      = "ZmFrZXNlY3JldA=="
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
