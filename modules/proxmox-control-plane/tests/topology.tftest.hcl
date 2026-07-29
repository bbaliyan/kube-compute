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

variables {
  cluster_name          = "bharat"
  k8s_version           = "v1.36.2+rke2r1"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  os_image_url          = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name    = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  cluster_token         = "test-cluster-token-0123456789"
  cluster_agent_token   = "test-agent-token-0123456789"
  cluster_ipset_name    = "kube-compute-bharat-cluster"
  etcd_ipset_name       = "kube-compute-bharat-etcd"
}

run "single_node_no_endpoint" {
  command = plan

  assert {
    condition     = output.registration_address == "192.168.1.10"
    error_message = "control_plane_count = 1 must fall back to the genesis node's own IP"
  }
  assert {
    condition     = length(proxmox_virtual_environment_vm.control_plane_additional) == 0
    error_message = "control_plane_count = 1 must create no additional control-plane VMs"
  }
}

run "invalid_control_plane_count_rejected" {
  command = plan
  variables {
    control_plane_count        = 2
    control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24"]
    cluster_domain             = "example.com"
    vm_gateway                 = "192.168.1.1"
  }
  expect_failures = [var.control_plane_count]
}

run "ha_control_plane_creates_n_minus_1_additional_vms" {
  command = plan
  variables {
    control_plane_count        = 3
    control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
    cluster_domain             = "example.com"
    cluster_network_cidr       = "192.168.1.0/24"
    vm_gateway                 = "192.168.1.1"
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.control_plane_additional) == 2
    error_message = "control_plane_count = 3 must create exactly 2 additional control-plane VMs"
  }
  assert {
    condition     = output.registration_address == "192.168.1.10"
    error_message = "control_plane_count > 1 must use genesis's own IP as registration_address — Proxmox has no VIP/load-balancer primitive"
  }
  assert {
    condition = alltrue([
      for k, v in proxmox_virtual_environment_file.hostname_init_additional :
      yamldecode(replace(v.source_raw[0].data, "#cloud-config\n", "")).hostname != yamldecode(replace(proxmox_virtual_environment_file.hostname_init.source_raw[0].data, "#cloud-config\n", "")).hostname
    ])
    error_message = "every additional control-plane node's hostname-init payload must differ from the genesis node's — rke2/kubelet default the registered Kubernetes node name to the OS hostname, so a collision makes every kubelet register as the same node, silently clobbering each other"
  }
  assert {
    condition = length(distinct([
      for k, v in proxmox_virtual_environment_file.hostname_init_additional :
      yamldecode(replace(v.source_raw[0].data, "#cloud-config\n", "")).hostname
    ])) == length(proxmox_virtual_environment_file.hostname_init_additional)
    error_message = "additional control-plane nodes must each get a distinct hostname from one another too, not just from genesis"
  }
  assert {
    condition     = length(output.control_plane_node_refs) == 3
    error_message = "control_plane_node_refs must have one entry per control-plane node"
  }
}
