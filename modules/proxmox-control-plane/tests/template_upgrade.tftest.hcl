# SPDX-License-Identifier: Apache-2.0
# A new proxmox_template_vm_id reaches only new VMs and VMs replaced on purpose,
# so one apply never rebuilds every control-plane node and etcd member.
#
# The runs check the clone source that each VM keeps in state. A mock provider
# cannot show more: it does not prove that the real provider plans no
# replacement, that a replaced node keeps its etcd data or rejoins the cluster,
# or that its firewall follows the new VM ID. `tofu test -verbose` shows the
# planned actions.
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
  cluster_name           = "bharat"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  os_image_url           = null
  os_image_file_name     = null
  proxmox_template_vm_id = 9000
}

run "single_node_is_created_from_the_template" {
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.clone[0].vm_id == 9000
    error_message = "a new node must be cloned from the configured template"
  }
}

run "new_template_keeps_the_single_node" {
  variables {
    proxmox_template_vm_id = 9001
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.clone[0].vm_id == 9000
    error_message = "a new template must not replace the existing node: one apply would rebuild the cluster"
  }
}

run "replace_moves_the_single_node_to_the_new_template" {
  variables {
    proxmox_template_vm_id = 9001
  }
  plan_options {
    replace = [proxmox_virtual_environment_vm.control_plane]
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.clone[0].vm_id == 9001
    error_message = "a node replaced on purpose must be cloned from the new template"
  }
}

run "new_control_plane_nodes_use_the_new_template" {
  variables {
    proxmox_template_vm_id     = 9002
    control_plane_count        = 3
    control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
    cluster_domain             = "example.com"
    cluster_network_cidr       = "192.168.1.0/24"
    vm_gateway                 = "192.168.1.1"
    dns_server_address         = "192.168.1.53"
    tsig_key_name              = "kube-compute"
    tsig_key_secret            = "ZmFrZXNlY3JldA=="
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.clone[0].vm_id == 9001
    error_message = "the existing first node must keep its template when the cluster grows"
  }
  assert {
    condition     = alltrue([for vm in proxmox_virtual_environment_vm.control_plane_additional : vm.clone[0].vm_id == 9002])
    error_message = "new control-plane nodes must be cloned from the configured template"
  }
}

run "replacing_one_additional_node_moves_only_that_node" {
  variables {
    proxmox_template_vm_id     = 9003
    control_plane_count        = 3
    control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
    cluster_domain             = "example.com"
    cluster_network_cidr       = "192.168.1.0/24"
    vm_gateway                 = "192.168.1.1"
    dns_server_address         = "192.168.1.53"
    tsig_key_name              = "kube-compute"
    tsig_key_secret            = "ZmFrZXNlY3JldA=="
  }
  plan_options {
    replace = [
      proxmox_virtual_environment_vm.control_plane_additional["1"],
      proxmox_virtual_environment_firewall_options.control_plane["1"],
      proxmox_virtual_environment_firewall_rules.control_plane["1"],
    ]
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane_additional["1"].clone[0].vm_id == 9003
    error_message = "the replaced node must be cloned from the new template"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane_additional["2"].clone[0].vm_id == 9002
    error_message = "a node that was not replaced must keep its template"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.clone[0].vm_id == 9001
    error_message = "the first node must keep its template while another node is replaced"
  }
}
