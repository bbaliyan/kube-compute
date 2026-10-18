# SPDX-License-Identifier: Apache-2.0
# pool_id and cpu_units are optional. Unset must leave the VM in no Proxmox
# pool and on the provider's default CPU weight, as before they existed.
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

# An apply would otherwise run nsupdate against the test's DNS server.
override_module {
  target  = module.dns_registration
  outputs = { fqdn = "api.bharat.example.com.", record_created = true }
}

override_module {
  target  = module.dns_registration_wildcard
  outputs = { fqdn = "*.bharat.example.com.", record_created = true }
}

variables {
  cluster_name          = "bharat"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  control_plane_count   = 3
  os_image_url          = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name    = "ubuntu-26.04-server-cloudimg-amd64.qcow2"

  control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
  cluster_domain             = "example.com"
  cluster_network_cidr       = "192.168.1.0/24"
  vm_gateway                 = "192.168.1.1"
  dns_server_address         = "192.168.1.53"
  tsig_key_name              = "kube-compute"
  tsig_key_secret            = "ZmFrZXNlY3JldA=="
}

run "unset_means_no_pool_and_default_cpu_weight" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.pool_id == null
    error_message = "genesis must not join a pool when pool_id is unset"
  }
  # The mock reports a computed units as 0, so unset is checked on the output
  # that carries the input, not on the VM attribute.
  assert {
    condition     = output.cpu_units == null
    error_message = "cpu_units must stay null so the provider keeps its default CPU weight"
  }
  assert {
    condition = alltrue([
      for vm in proxmox_virtual_environment_vm.control_plane_additional : vm.pool_id == null
    ])
    error_message = "additional control-plane VMs must have no pool when unset"
  }
}

run "set_applies_to_every_control_plane_vm" {
  command = plan
  variables {
    pool_id   = "kube"
    cpu_units = 100
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.pool_id == "kube"
    error_message = "genesis must join the pool named by pool_id"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.cpu[0].units == 100
    error_message = "genesis must carry cpu_units as its CPU weight"
  }
  assert {
    condition = alltrue([
      for vm in proxmox_virtual_environment_vm.control_plane_additional : vm.pool_id == "kube" && vm.cpu[0].units == 100
    ])
    error_message = "additional control-plane VMs must join the pool and carry cpu_units"
  }
}
