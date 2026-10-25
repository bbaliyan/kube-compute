# SPDX-License-Identifier: Apache-2.0
# cloud_init_upload_mode is optional. Unset must leave every snippet on the
# provider default, as before it existed. Set to sftp it must reach every one.
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name         = "bharat"
  proxmox_node         = "pve"
  vm_cores             = 2
  vm_memory_mb         = 4096
  vm_disk_gb           = 30
  desired_count        = 2
  registration_address = "192.168.1.5"
  cluster_agent_token  = "agent-secret-abc123"
  os_image_url         = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name   = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "unset_keeps_the_provider_default" {
  command = plan

  assert {
    condition = alltrue([
      proxmox_virtual_environment_file.vendor_data.upload_mode == null,
      alltrue([for f in proxmox_virtual_environment_file.network_data : f.upload_mode == null]),
      alltrue([for f in proxmox_virtual_environment_file.node_init : f.upload_mode == null]),
    ])
    error_message = "upload_mode must stay null on every snippet when cloud_init_upload_mode is unset"
  }
  assert {
    condition     = output.cloud_init_upload_mode == null
    error_message = "the output must be null when the input is unset"
  }
}

run "sftp_reaches_every_snippet" {
  command = plan
  variables {
    cloud_init_upload_mode = "sftp"
  }

  assert {
    condition = alltrue([
      proxmox_virtual_environment_file.vendor_data.upload_mode == "sftp",
      length(proxmox_virtual_environment_file.network_data) == 2,
      alltrue([for f in proxmox_virtual_environment_file.network_data : f.upload_mode == "sftp"]),
      length(proxmox_virtual_environment_file.node_init) == 2,
      alltrue([for f in proxmox_virtual_environment_file.node_init : f.upload_mode == "sftp"]),
    ])
    error_message = "every snippet (vendor, network data, node-init) must use sftp"
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
