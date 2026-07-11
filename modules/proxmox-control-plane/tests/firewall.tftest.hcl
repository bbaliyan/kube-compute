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

run "cluster_and_etcd_ipsets_created_and_referenced" {
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
    condition     = proxmox_virtual_environment_firewall_ipset.cluster.name == "kube-compute-bharat-cluster"
    error_message = "cluster ipset must be named predictably so node pools can reference it by name"
  }
  assert {
    condition     = output.cluster_ipset_name == "kube-compute-bharat-cluster"
    error_message = "cluster_ipset_name output must match the ipset actually created"
  }
  assert {
    condition     = length(proxmox_virtual_environment_firewall_ipset.etcd.cidr) == 3
    error_message = "etcd ipset must contain exactly one cidr entry per control-plane node"
  }
  assert {
    condition     = alltrue([for r in proxmox_virtual_environment_firewall_rules.control_plane["0"].rule : true if strcontains(coalesce(r.source, ""), "kube-compute-bharat-cluster") || strcontains(coalesce(r.source, ""), "kube-compute-bharat-etcd") || contains(var.allowed_ingress_cidrs, coalesce(r.source, ""))])
    error_message = "every control-plane firewall rule's source must be the cluster ipset, the etcd ipset, or an allowed ingress CIDR"
  }
}
