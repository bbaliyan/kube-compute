# SPDX-License-Identifier: Apache-2.0
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/app-red.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/app-red.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name               = "app-red"
  proxmox_node               = "pve"
  vm_cores                   = 4
  vm_memory_mb               = 8192
  vm_disk_gb                 = 50
  control_plane_count        = 3
  control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
  cluster_domain             = "red.lan"
  cluster_network_cidr       = "192.168.1.0/24"
  vm_gateway                 = "192.168.1.1"
  allowed_ingress_cidrs      = ["192.168.1.0/24"]
  os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  dns_server_address         = "192.168.1.53"
  tsig_key_name              = "kube-compute"
  tsig_key_secret            = "ZmFrZXNlY3JldA=="
}

run "unset_template_keeps_the_names" {
  command = plan

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.name == "app-red-cp-0"
    error_message = "unset, the first VM must keep its name: got ${proxmox_virtual_environment_vm.control_plane.name}"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane_additional["2"].name == "app-red-cp-2"
    error_message = "unset, the other VMs must keep their names"
  }
  assert {
    condition     = toset(keys(output.control_plane_node_refs)) == toset(["app-red-cp-0", "app-red-cp-1", "app-red-cp-2"])
    error_message = "unset, control_plane_node_refs must keep its keys: got ${jsonencode(keys(output.control_plane_node_refs))}"
  }
}

run "template_names_every_node" {
  command = plan

  variables {
    node_name_template = "cp-red-{number}"
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.name == "cp-red-01"
    error_message = "the first VM must take number 01: got ${proxmox_virtual_environment_vm.control_plane.name}"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane_additional["2"].name == "cp-red-03"
    error_message = "the third VM must take number 03"
  }
  assert {
    condition     = toset(keys(output.control_plane_node_refs)) == toset(["cp-red-01", "cp-red-02", "cp-red-03"])
    error_message = "control_plane_node_refs must be keyed by the new names: got ${jsonencode(keys(output.control_plane_node_refs))}"
  }
}

run "template_without_number_is_rejected" {
  command = plan

  variables {
    node_name_template = "cp-red"
  }

  expect_failures = [var.node_name_template]
}

run "template_with_invalid_hostname_is_rejected" {
  command = plan

  variables {
    node_name_template = "CP_{number}"
  }

  expect_failures = [var.node_name_template]
}

# The node payloads embed generated tokens, so reading them needs an apply, and an apply
# would otherwise run nsupdate against the test's DNS server.
run "no_boot_scripts_leaves_plain_cloud_config" {
  command = apply

  override_module {
    target  = module.dns_registration
    outputs = { fqdn = "api.app-red.red.lan.", record_created = true }
  }
  override_module {
    target  = module.dns_registration_wildcard
    outputs = { fqdn = "*.app-red.red.lan.", record_created = true }
  }

  assert {
    condition = alltrue([
      for snippet in concat([proxmox_virtual_environment_file.node_init], values(proxmox_virtual_environment_file.node_init_additional)) :
      startswith(snippet.source_raw[0].data, "#cloud-config")
    ])
    error_message = "with no boot_scripts the snippet must stay a plain cloud-config"
  }
}

run "boot_scripts_run_first_on_every_node_with_its_name" {
  command = apply

  variables {
    node_name_template = "cp-red-{number}"
    boot_scripts       = ["echo one", "echo two"]
  }

  override_module {
    target  = module.dns_registration
    outputs = { fqdn = "api.app-red.red.lan.", record_created = true }
  }
  override_module {
    target  = module.dns_registration_wildcard
    outputs = { fqdn = "*.app-red.red.lan.", record_created = true }
  }

  assert {
    condition = alltrue([
      for snippet in concat([proxmox_virtual_environment_file.node_init], values(proxmox_virtual_environment_file.node_init_additional)) :
      startswith(snippet.source_raw[0].data, "Content-Type: multipart/mixed")
      && length(regexall("(?m)^echo (one|two)$", snippet.source_raw[0].data)) == 2
      && strcontains(snippet.source_raw[0].data, "Content-Type: text/cloud-config")
    ])
    error_message = "every node must get both scripts ahead of its cloud-config"
  }
  assert {
    condition     = strcontains(proxmox_virtual_environment_file.node_init_additional["1"].source_raw[0].data, "NODE_NAME='cp-red-02'")
    error_message = "a script must see the node's own name"
  }
  assert {
    condition     = strcontains(proxmox_virtual_environment_file.node_init.source_raw[0].data, "NODE_ROLE='control-plane'")
    error_message = "a script must see the control-plane role"
  }
  assert {
    condition     = index(split("\n", proxmox_virtual_environment_file.node_init.source_raw[0].data), "echo one") < index(split("\n", proxmox_virtual_environment_file.node_init.source_raw[0].data), "echo two")
    error_message = "scripts must run in the order given"
  }
}

run "boot_script_may_not_end_its_own_heredoc" {
  command = plan

  variables {
    boot_scripts = ["echo hi\nKUBE_COMPUTE_BOOT_SCRIPT\nrm -rf /"]
  }

  expect_failures = [var.boot_scripts]
}
