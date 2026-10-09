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
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name        = "app-red"
  pool_name           = "workers"
  proxmox_node        = "pve"
  vm_cores            = 2
  vm_memory_mb        = 4096
  vm_disk_gb          = 30
  desired_count       = 2
  cluster_agent_token = "agent-secret-abc123"
  cluster_domain      = "red.lan"
  dns_server_address  = "192.168.1.53"
  tsig_key_name       = "kube-compute"
  tsig_key_secret     = "ZmFrZXNlY3JldA=="
  os_image_url        = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name  = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "cluster_dns_name_names_the_join_address" {
  command = plan

  variables {
    cluster_dns_name = "app"
  }

  assert {
    condition = alltrue([
      for snippet in values(proxmox_virtual_environment_file.node_init) :
      anytrue([
        for f in yamldecode(snippet.source_raw[0].data).write_files :
        strcontains(base64decode(f.content), "genesis.app.red.lan")
      ])
    ])
    error_message = "workers must join through genesis.<cluster_dns_name>.<cluster_domain>"
  }
  assert {
    condition     = alltrue([for vm in values(proxmox_virtual_environment_vm.worker) : startswith(vm.name, "app-red-")])
    error_message = "VM names must stay on cluster_name"
  }
}

run "graceful_shutdown_reaches_every_worker" {
  command = plan

  variables {
    graceful_shutdown = { seconds = 300, critical_seconds = 60 }
  }

  assert {
    condition = alltrue([
      for snippet in values(proxmox_virtual_environment_file.node_init) :
      anytrue([
        for f in yamldecode(snippet.source_raw[0].data).write_files :
        strcontains(base64decode(f.content), "shutdownGracePeriod: 300s")
        if f.path == "/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf"
      ])
    ])
    error_message = "every worker must carry the configured shutdown grace period"
  }
}
