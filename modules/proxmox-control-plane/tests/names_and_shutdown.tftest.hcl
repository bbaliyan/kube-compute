# SPDX-License-Identifier: Apache-2.0
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/app-red.img" }
  }
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
  os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  dns_server_address         = "192.168.1.53"
  tsig_key_name              = "kube-compute"
  tsig_key_secret            = "ZmFrZXNlY3JldA=="
}

run "without_cluster_dns_name_dns_uses_the_cluster_name" {
  command = plan

  assert {
    condition     = output.cluster_fqdn == "api.app-red.red.lan"
    error_message = "unset, cluster_dns_name must leave the name as it was: got ${output.cluster_fqdn}"
  }
}

run "cluster_dns_name_replaces_the_cluster_name_in_dns" {
  command = plan

  variables {
    cluster_dns_name = "app"
  }

  assert {
    condition     = output.cluster_fqdn == "api.app.red.lan"
    error_message = "the FQDN must use cluster_dns_name: got ${output.cluster_fqdn}"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.app.red.lan"
    error_message = "the wildcard must follow the FQDN: got ${output.wildcard_dns_name}"
  }
  assert {
    condition     = module.dns_registration.fqdn == "api.app.red.lan."
    error_message = "the published API record must use cluster_dns_name: got ${module.dns_registration.fqdn}"
  }
}

# The node payloads embed generated tokens, so reading them needs an apply, and an apply
# would otherwise run nsupdate against the test's DNS server.
run "genesis_serves_the_join_name_and_vms_keep_the_cluster_name" {
  command = apply

  variables {
    cluster_dns_name = "app"
  }

  override_module {
    target  = module.dns_registration
    outputs = { fqdn = "api.app.red.lan.", record_created = true }
  }
  override_module {
    target  = module.dns_registration_wildcard
    outputs = { fqdn = "*.app.red.lan.", record_created = true }
  }

  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "genesis.app.red.lan")
    ])
    error_message = "genesis must serve genesis.<cluster_dns_name>.<cluster_domain>, the name the other nodes join through"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.name == "app-red-cp-0"
    error_message = "VM names must stay on cluster_name"
  }
}

run "graceful_shutdown_reaches_every_control_plane_node" {
  command = apply

  variables {
    graceful_shutdown = { seconds = 300, critical_seconds = 60 }
  }

  override_module {
    target  = module.dns_registration
    outputs = { fqdn = "api.app-red.red.lan.", record_created = true }
  }
  override_module {
    target  = module.dns_registration_wildcard
    outputs = { fqdn = "*.app-red.red.lan.", record_created = true }
  }

  assert {
    condition = alltrue([
      for snippet in concat([proxmox_virtual_environment_file.node_init], values(proxmox_virtual_environment_file.node_init_additional)) :
      anytrue([
        for f in yamldecode(snippet.source_raw[0].data).write_files :
        strcontains(base64decode(f.content), "shutdownGracePeriod: 300s")
        if f.path == "/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf"
      ])
    ])
    error_message = "every control-plane node must carry the configured shutdown grace period"
  }
}

run "graceful_shutdown_null_writes_no_drop_in" {
  command = apply

  variables {
    graceful_shutdown = null
  }

  override_module {
    target  = module.dns_registration
    outputs = { fqdn = "api.app-red.red.lan.", record_created = true }
  }
  override_module {
    target  = module.dns_registration_wildcard
    outputs = { fqdn = "*.app-red.red.lan.", record_created = true }
  }

  assert {
    condition = alltrue([
      for snippet in concat([proxmox_virtual_environment_file.node_init], values(proxmox_virtual_environment_file.node_init_additional)) :
      !strcontains(snippet.source_raw[0].data, "10-graceful-shutdown.conf")
    ])
    error_message = "graceful_shutdown = null must leave the kubelet drop-in out"
  }
}
