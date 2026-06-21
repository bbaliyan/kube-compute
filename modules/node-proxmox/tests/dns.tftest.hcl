# SPDX-License-Identifier: Apache-2.0
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/dns-test.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/dns-test.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["10.0.0.5", "127.0.0.1"]]
    }
  }
}

run "cluster_domain_produces_names" {
  command = plan
  variables {
    cluster_name   = "bharat"
    k8s_version    = "v1.36.1+k3s1"
    proxmox_node   = "pve"
    vm_cores       = 4
    vm_memory_mb   = 8192
    vm_disk_gb     = 50
    vm_ip_address  = "10.0.0.5/24"
    vm_gateway     = "10.0.0.1"
    os_image_url   = "https://example.com/rocky10.img"
    cluster_domain = "homelab.local"
  }
  assert {
    condition     = output.cluster_fqdn == "api.bharat.homelab.local"
    error_message = "cluster_fqdn must be api.<cluster_name>.<cluster_domain>"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.bharat.homelab.local"
    error_message = "wildcard_dns_name must be *.<cluster_name>.<cluster_domain>"
  }
}

run "no_domain_is_ip_only" {
  command = plan
  variables {
    cluster_name  = "bharat"
    k8s_version   = "v1.36.1+k3s1"
    proxmox_node  = "pve"
    vm_cores      = 4
    vm_memory_mb  = 8192
    vm_disk_gb    = 50
    vm_ip_address = "10.0.0.5/24"
    vm_gateway    = "10.0.0.1"
    os_image_url  = "https://example.com/rocky10.img"
    # cluster_domain omitted — IP-only mode
  }
  assert {
    condition     = output.cluster_fqdn == null
    error_message = "no cluster_domain must yield null cluster_fqdn"
  }
  assert {
    condition     = output.wildcard_dns_name == null
    error_message = "no cluster_domain must yield null wildcard_dns_name"
  }
}
