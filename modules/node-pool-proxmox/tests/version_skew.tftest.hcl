# SPDX-License-Identifier: Apache-2.0
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

run "newer_pool_version_rejected" {
  command = plan
  variables {
    cluster_name              = "bharat"
    k8s_version               = "v1.37.0+k3s1"
    control_plane_k8s_version = "v1.36.1+k3s1"
    proxmox_node              = "pve"
    vm_cores                  = 2
    vm_memory_mb              = 4096
    vm_disk_gb                = 30
    desired_count             = 1
    registration_address      = "192.168.1.5"
    cluster_agent_token       = "agent-secret-abc123"
    cluster_ipset_name        = "kube-compute-bharat-cluster"
    os_image_url              = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name        = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }
  expect_failures = [proxmox_virtual_environment_vm.worker]
}
