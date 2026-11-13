# SPDX-License-Identifier: Apache-2.0
# pool_id are optional. Unset must leave the VM in no Proxmox
# pool, as before it existed.
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

# An apply would otherwise run nsupdate against the test's DNS server.
override_module {
  target  = module.dns_registration
  outputs = { fqdn = "api.example.example.com.", record_created = true }
}

override_module {
  target  = module.dns_registration_wildcard
  outputs = { fqdn = "*.example.example.com.", record_created = true }
}

variables {
  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  control_plane_count    = 3
  proxmox_template_vm_id = 9000

  cluster_domain       = "example.com"
  cluster_network_cidr = "192.168.1.0/24"
  dns_server_address   = "192.168.1.53"
  tsig_key_name        = "kube-compute"
  tsig_key_secret      = "ZmFrZXNlY3JldA=="
}

run "unset_means_no_pool" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].pool_id == null
    error_message = "genesis must not join a pool when pool_id is unset"
  }
  assert {
    condition = alltrue([
      for vm in [for k, v in proxmox_virtual_environment_vm.control_plane : v if k != "0"] : vm.pool_id == null
    ])
    error_message = "additional control-plane VMs must have no pool when unset"
  }
}

run "set_applies_to_every_control_plane_vm" {
  command = plan
  variables {
    pool_id = "kube"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].pool_id == "kube"
    error_message = "genesis must join the pool named by pool_id"
  }
  assert {
    condition = alltrue([
      for vm in [for k, v in proxmox_virtual_environment_vm.control_plane : v if k != "0"] : vm.pool_id == "kube"
    ])
    error_message = "additional control-plane VMs must join the pool"
  }
}
