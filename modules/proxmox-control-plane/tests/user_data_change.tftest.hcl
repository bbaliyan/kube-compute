# SPDX-License-Identifier: Apache-2.0
# The user data hashes of a three-node control plane. A VM is replaced when the
# input of its entry moves; aws-control-plane's user_data_change test shows
# that behaviour, which this module shares. The runs share one state and run
# in order. Every run is an apply, because the snippet carries a generated
# token and is unknown at plan.
#
# What a mock cannot show: the mock gives a VM the same id and vm_id each time
# it creates one, so these runs cannot tell a kept VM from a replaced one. The
# Proxmox API is not called, and the mock gives the snippet the same file id
# before and after its content changes, so they do not show what the real
# provider plans for the VM when the snippet is rewritten, or what cloud-init
# does on the VM. They show the hashes that trigger a replacement, and that the
# module applies and destroys with them.
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

# An apply would otherwise run nsupdate against the test's DNS server. Overriding
# the resource is not enough: its provisioners still run.
override_module {
  target  = module.dns_registration
  outputs = { fqdn = "api.bharat.example.com.", record_created = true }
}

override_module {
  target  = module.dns_registration_wildcard
  outputs = { fqdn = "*.bharat.example.com.", record_created = true }
}

variables {
  cluster_name               = "bharat"
  proxmox_node               = "pve"
  vm_cores                   = 4
  vm_memory_mb               = 8192
  vm_disk_gb                 = 50
  allowed_ingress_cidrs      = ["192.168.1.0/24"]
  os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  control_plane_count        = 3
  control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
  cluster_domain             = "example.com"
  cluster_network_cidr       = "192.168.1.0/24"
  vm_gateway                 = "192.168.1.1"
  dns_server_address         = "192.168.1.53"
  tsig_key_name              = "kube-compute"
  tsig_key_secret            = "ZmFrZXNlY3JldA=="
}

run "create" {
  command = apply

  variables {
    platform_extra_helm_parameters = {
      "global.example" = "one"
    }
  }

  assert {
    condition     = terraform_data.genesis_user_data.input == sha256(proxmox_virtual_environment_file.node_init.source_raw[0].data)
    error_message = "the first VM's entry must start with the hash of its snippet"
  }
  assert {
    condition     = toset(keys(terraform_data.additional_user_data)) == toset(["0", "1", "2"])
    error_message = "every firewall key must have an additional_user_data entry"
  }
  assert {
    condition = terraform_data.genesis_user_data.triggers_replace == null && alltrue([
      for t in values(terraform_data.additional_user_data) : t.triggers_replace == null
    ])
    error_message = "by default no user data hash may be tracked"
  }
}

run "default_does_not_move_the_hash_when_the_snippet_changes" {
  command = apply

  variables {
    platform_extra_helm_parameters = {
      "global.example" = "two"
    }
  }

  assert {
    condition     = terraform_data.genesis_user_data.input != sha256(proxmox_virtual_environment_file.node_init.source_raw[0].data)
    error_message = "by default a snippet change must not reach the first VM's entry, which would replace the VM"
  }
}

run "turning_the_opt_in_on_moves_the_hash_of_a_vm_changed_while_it_was_off" {
  command = apply

  variables {
    replace_on_user_data_change = true
    platform_extra_helm_parameters = {
      "global.example" = "two"
    }
  }

  assert {
    condition     = terraform_data.genesis_user_data.input == sha256(proxmox_virtual_environment_file.node_init.source_raw[0].data)
    error_message = "the snippet changed while the opt-in was off, so turning it on must move the first VM's hash"
  }
  assert {
    condition = alltrue([
      for k, f in proxmox_virtual_environment_file.node_init_additional :
      terraform_data.additional_user_data[k].input == sha256(f.source_raw[0].data) &&
      terraform_data.additional_user_data[k].triggers_replace == terraform_data.additional_user_data[k].input
    ])
    error_message = "with replace_on_user_data_change every additional VM's current snippet hash must be tracked"
  }
}

run "opt_in_moves_the_hash_when_the_snippet_changes" {
  command = apply

  variables {
    replace_on_user_data_change = true
    platform_extra_helm_parameters = {
      "global.example" = "three"
    }
  }

  assert {
    condition     = terraform_data.genesis_user_data.input == sha256(proxmox_virtual_environment_file.node_init.source_raw[0].data)
    error_message = "with replace_on_user_data_change a snippet change must move the first VM's hash"
  }
}
