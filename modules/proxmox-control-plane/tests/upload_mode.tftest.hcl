# SPDX-License-Identifier: Apache-2.0
# cloud_init_upload_mode is optional. Unset must leave every snippet on the
# provider default, as before it existed. Set to sftp it must reach every one.
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

  control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
  cluster_domain             = "example.com"
  cluster_network_cidr       = "192.168.1.0/24"
  vm_gateway                 = "192.168.1.1"
  dns_server_address         = "192.168.1.53"
  tsig_key_name              = "kube-compute"
  tsig_key_secret            = "ZmFrZXNlY3JldA=="
}

run "unset_keeps_the_provider_default" {
  command = plan

  assert {
    condition = alltrue([
      proxmox_virtual_environment_file.vendor_data.upload_mode == null,
      proxmox_virtual_environment_file.node_init["0"].upload_mode == null,
      alltrue([for f in [for k, v in proxmox_virtual_environment_file.node_init : v if k != "0"] : f.upload_mode == null]),
      alltrue([for f in proxmox_virtual_environment_file.network_data : f.upload_mode == null]),
    ])
    error_message = "upload_mode must stay null on every snippet when cloud_init_upload_mode is unset"
  }
  assert {
    condition     = output.cloud_init_upload_mode == null
    error_message = "the output must be null when the input is unset"
  }
}

run "sftp_reaches_every_static_snippet" {
  command = plan
  variables {
    cloud_init_upload_mode = "sftp"
  }

  assert {
    condition = alltrue([
      proxmox_virtual_environment_file.vendor_data.upload_mode == "sftp",
      proxmox_virtual_environment_file.node_init["0"].upload_mode == "sftp",
      length(proxmox_virtual_environment_file.node_init) == 3,
      alltrue([for f in [for k, v in proxmox_virtual_environment_file.node_init : v if k != "0"] : f.upload_mode == "sftp"]),
      length(proxmox_virtual_environment_file.network_data) == 3,
      alltrue([for f in proxmox_virtual_environment_file.network_data : f.upload_mode == "sftp"]),
    ])
    error_message = "every snippet (vendor, node-init, additional node-init, network data) must use sftp"
  }
}

run "sftp_reaches_the_dhcp_network_snippet" {
  command = plan
  variables {
    cloud_init_upload_mode     = "sftp"
    control_plane_count        = 1
    control_plane_ip_addresses = null
    vm_gateway                 = null
  }

  assert {
    condition     = length(proxmox_virtual_environment_file.network_data_dhcp) == 1 && proxmox_virtual_environment_file.network_data_dhcp[0].upload_mode == "sftp"
    error_message = "the DHCP network-data snippet must use sftp too"
  }
}

run "stream_is_accepted" {
  command = plan
  variables {
    cloud_init_upload_mode = "stream"
  }

  assert {
    condition     = proxmox_virtual_environment_file.node_init["0"].upload_mode == "stream"
    error_message = "stream must be accepted and passed through"
  }
}

run "a_bad_value_is_rejected" {
  command = plan
  variables {
    cloud_init_upload_mode = "scp"
  }

  expect_failures = [var.cloud_init_upload_mode]
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
