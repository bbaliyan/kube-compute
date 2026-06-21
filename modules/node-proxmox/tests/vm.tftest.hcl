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

run "static_ip_x86" {
  command = plan
  variables {
    cluster_name  = "bharat"
    k8s_version   = "v1.36.1+k3s1"
    proxmox_node  = "pve"
    vm_cores      = 4
    vm_memory_mb  = 8192
    vm_disk_gb    = 50
    vm_ip_address = "192.168.1.10/24"
    vm_gateway    = "192.168.1.1"
    os_image_url  = "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud.latest.x86_64.qcow2"
  }
  assert {
    condition     = output.cluster_ip == "192.168.1.10"
    error_message = "static vm_ip_address must have its CIDR prefix stripped"
  }
  assert {
    condition     = output.node_provider == "proxmox"
    error_message = "node_provider must be the literal string 'proxmox'"
  }
  assert {
    condition     = output.node_arch == "x86_64"
    error_message = "node_arch default must be x86_64"
  }
  assert {
    condition     = output.cluster_fqdn == null
    error_message = "no cluster_domain means cluster_fqdn must be null"
  }
  assert {
    condition     = output.wildcard_dns_name == null
    error_message = "no cluster_domain means wildcard_dns_name must be null"
  }
  assert {
    condition     = output.instance_id == "100"
    error_message = "instance_id must be the Proxmox vm_id cast to string"
  }
  assert {
    condition     = output.bootstrap_status_ref == "100"
    error_message = "bootstrap_status_ref must equal instance_id (vm_id as string)"
  }
}

run "arm64_explicit" {
  command = plan
  variables {
    cluster_name  = "arm-lab"
    k8s_version   = "v1.36.1+k3s1"
    proxmox_node  = "pve"
    vm_cores      = 4
    vm_memory_mb  = 8192
    vm_disk_gb    = 50
    node_arch     = "arm64"
    vm_ip_address = "192.168.1.20/24"
    vm_gateway    = "192.168.1.1"
    os_image_url  = "https://dl.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud.latest.aarch64.qcow2"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "explicit node_arch = arm64 must pass through to the output"
  }
}

run "dhcp_ip_from_agent" {
  command = apply
  # vm_ip_address omitted → DHCP path; cluster_ip comes from mock agent ipv4_addresses.
  # The 127.0.0.1 loopback entry must be filtered out.
  variables {
    cluster_name = "dhcp-test"
    k8s_version  = "v1.36.1+k3s1"
    proxmox_node = "pve"
    vm_cores     = 2
    vm_memory_mb = 4096
    vm_disk_gb   = 30
    os_image_url = "https://dl.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud.latest.x86_64.qcow2"
  }
  assert {
    condition     = output.cluster_ip == "192.168.1.10"
    error_message = "DHCP cluster_ip must be first non-loopback IP from mock agent data"
  }
}

run "preexisting_image_skips_download" {
  command = plan
  variables {
    cluster_name     = "shared"
    k8s_version      = "v1.36.1+k3s1"
    proxmox_node     = "pve"
    vm_cores         = 4
    vm_memory_mb     = 8192
    vm_disk_gb       = 50
    vm_ip_address    = "192.168.1.30/24"
    vm_gateway       = "192.168.1.1"
    os_image_file_id = "local:iso/rocky10-shared.img"
  }
  assert {
    condition     = length(proxmox_download_file.os_image) == 0
    error_message = "providing os_image_file_id must suppress the download resource (count = 0)"
  }
}
