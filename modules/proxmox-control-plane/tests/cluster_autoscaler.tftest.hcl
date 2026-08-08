# SPDX-License-Identifier: Apache-2.0
# Guards the cluster_autoscaler_* variable validation added alongside the
# clusterAutoscalerEnabled pass-through: enabling the toggle without a
# complete configuration must fail at plan time with a clear message, not a
# raw "Attempt to get attribute from null value" error deep in node-bootstrap.
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}
mock_provider "dns" {}

variables {
  cluster_name          = "bharat"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  os_image_url          = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name    = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "cluster_autoscaler_enabled_without_template_fails_validation" {
  command = plan
  variables {
    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 1
    cluster_autoscaler_worker_max_size = 3
  }
  expect_failures = [var.cluster_autoscaler_worker_template]
}

run "cluster_autoscaler_enabled_with_zero_max_size_fails_validation" {
  command = plan
  variables {
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_template = {
      vm_cores               = 4
      vm_memory_mb            = 4096
      vm_disk_gb              = 40
      proxmox_template_vm_id  = 9100
      network_bridge          = "vmbr0"
      disk_datastore_id       = "local-lvm"
      proxmox_node            = "pve1"
    }
  }
  expect_failures = [var.cluster_autoscaler_worker_max_size]
}
