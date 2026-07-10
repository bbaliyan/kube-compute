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
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}

run "kube_vip_manifest_renders_with_configured_vip" {
  command = apply
  variables {
    cluster_name               = "bharat"
    k8s_version                = "v1.36.1+k3s1"
    proxmox_node               = "pve"
    vm_cores                   = 4
    vm_memory_mb               = 8192
    vm_disk_gb                 = 50
    control_plane_count        = 3
    control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
    control_plane_vip_address  = "192.168.1.5"
    cluster_network_cidr       = "192.168.1.0/24"
    vm_gateway                 = "192.168.1.1"
    allowed_ingress_cidrs      = ["192.168.1.0/24"]
    os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }

  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "kind: DaemonSet")
    error_message = "the genesis node's cloud-init must carry the kube-vip DaemonSet manifest when control_plane_count > 1"
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "value: \"192.168.1.5\"")
    error_message = "the kube-vip manifest must be configured with the operator's control_plane_vip_address"
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "/var/lib/rancher/k3s/server/manifests/kube-vip.yaml")
    error_message = "the kube-vip manifest must land in K3s's auto-deploy manifests directory via extra_server_manifests"
  }
}
