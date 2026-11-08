# SPDX-License-Identifier: Apache-2.0
# Guards the kube-images template-clone path: cloning must always be a FULL
# clone (a linked clone leaves every node depending on a template that
# kube-images' own prune-images.sh will eventually delete), the disk must not
# also try to import a stock image.
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
  argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256 = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
}

run "template_clone_is_always_a_full_clone" {
  command = plan
  variables {
    proxmox_template_vm_id = 9000
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.control_plane["0"].clone) == 1
    error_message = "a supplied proxmox_template_vm_id must produce exactly one clone block"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].clone[0].vm_id == 9000
    error_message = "the clone block must reference the supplied template VM ID"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].clone[0].full == true
    error_message = "full must be true on every clone — a linked clone makes every node permanently depend on the kube-images template, which breaks the moment prune-images.sh deletes it"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane["0"].disk[0].import_from == null
    error_message = "a cloned VM must not also import a stock image — the clone already brings its own disk"
  }
}
