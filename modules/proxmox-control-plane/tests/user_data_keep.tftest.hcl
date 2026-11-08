# SPDX-License-Identifier: Apache-2.0
# A changed Helm parameter rewrites the cloud-init snippet but not the running
# VM. The runs share one state and run in order. Every run is an apply, because
# the snippet carries a generated token and is unknown at plan.
#
# What a mock cannot show: the mock gives a VM the same id and vm_id each time
# it creates one, and the snippet the same file id before and after its content
# changes. These runs do not prove what the real provider plans for the VM when
# the snippet is rewritten, or what cloud-init does on a replaced VM. The
# snippet is base64 encoded, so the runs do not show its new content either.
# They show only that the module still plans and applies with a changed input
# and that the VM keeps its snippet reference and clone source.
mock_provider "proxmox" {
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
  argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256 = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
  cluster_name           = "bharat"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  proxmox_template_vm_id = 9000
  platform_extra_helm_parameters = {
    "global.example" = "first-value"
  }
}

run "create" {
  command = apply

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].initialization[0].user_data_file_id == proxmox_virtual_environment_file.node_init["0"].id
    error_message = "the VM must reference the snippet"
  }
}

run "keeps_the_vm_when_a_helm_parameter_changes" {
  command = apply

  variables {
    platform_extra_helm_parameters = {
      "global.example" = "second-value"
    }
  }

  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].initialization[0].user_data_file_id == proxmox_virtual_environment_file.node_init["0"].id && proxmox_virtual_environment_vm.control_plane["0"].clone[0].vm_id == 9000
    error_message = "a user data change must leave the VM as it was"
  }
}
