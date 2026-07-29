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
mock_provider "dns" {}

variables {
  cluster_name               = "bharat"
  k8s_version                = "v1.36.2+rke2r1"
  proxmox_node               = "pve"
  vm_cores                   = 4
  vm_memory_mb               = 8192
  vm_disk_gb                 = 50
  control_plane_count        = 3
  control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
  cluster_domain             = "lan"
  cluster_network_cidr       = "192.168.1.0/24"
  vm_gateway                 = "192.168.1.1"
  allowed_ingress_cidrs      = ["192.168.1.0/24"]
  os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  cluster_token              = "test-cluster-token-0123456789"
  cluster_agent_token        = "test-agent-token-0123456789"
  cluster_ipset_name         = "kube-compute-bharat-cluster"
  etcd_ipset_name            = "kube-compute-bharat-etcd"
}

run "dns_registration_enabled_when_server_supplied" {
  command = plan
  variables {
    dns_server_address = "192.168.1.53"
    tsig_key_name      = "kube-compute"
    tsig_key_secret    = "ZmFrZXNlY3JldA=="
  }

  assert {
    condition     = module.dns_registration.fqdn == "api.bharat.lan."
    error_message = "dns_registration's fqdn output must combine cluster_name and cluster_domain correctly"
  }
  assert {
    condition     = module.dns_registration.record_created == true
    error_message = "dns_server_address set must actually create the dns_a_record_set resource"
  }
  assert {
    condition     = output.dns_registration_enabled == true
    error_message = "dns_registration_enabled output must reflect that dns_server_address was supplied"
  }
}

run "dns_registration_disabled_without_server" {
  command = plan
  variables {
    control_plane_count        = 1
    control_plane_ip_addresses = ["192.168.1.10/24"]
  }

  assert {
    condition     = module.dns_registration.record_created == false
    error_message = "no dns_server_address must skip creating the dns_a_record_set resource — DNS registration is optional"
  }
  assert {
    condition     = output.dns_registration_enabled == false
    error_message = "dns_registration_enabled output must be false when dns_server_address is unset, even though cluster_fqdn is still non-null — consumers must not join via cluster_fqdn in this case"
  }
}
