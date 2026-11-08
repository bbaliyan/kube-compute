# SPDX-License-Identifier: Apache-2.0
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/example.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}

variables {
  argocd_manifest_url        = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256     = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
  cluster_name               = "example"
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
  proxmox_template_vm_id     = 9000
}

run "dns_registration_enabled_when_server_supplied" {
  command = plan
  variables {
    dns_server_address = "192.168.1.53"
    tsig_key_name      = "kube-compute"
    tsig_key_secret    = "ZmFrZXNlY3JldA=="
  }

  assert {
    condition     = module.dns_registration.fqdn == "api.example.lan."
    error_message = "dns_registration's fqdn output must combine cluster_name and cluster_domain correctly"
  }
  assert {
    condition     = module.dns_registration.record_created == true
    error_message = "dns_server_address set must publish the record"
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
    error_message = "no dns_server_address must publish no record — DNS registration is optional"
  }
  assert {
    condition     = output.dns_registration_enabled == false
    error_message = "dns_registration_enabled output must be false when dns_server_address is unset, even though cluster_fqdn is still non-null — consumers must not join via cluster_fqdn in this case"
  }
}
