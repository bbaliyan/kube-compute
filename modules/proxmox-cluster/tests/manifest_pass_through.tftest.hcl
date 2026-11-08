# SPDX-License-Identifier: Apache-2.0
# genesis_apply_manifests reaches the control plane, whose own tests show that it
# reaches the genesis render.
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

variables {
  argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256 = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
  cluster_name           = "bharat"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  cluster_network_cidr   = "192.168.1.0/24"
  proxmox_template_vm_id = 9000
}

run "unset_adds_no_genesis_manifest" {
  command = plan

  assert {
    condition     = module.control_plane.genesis_apply_manifest_paths == []
    error_message = "unset, genesis_apply_manifests must reach the control plane as an empty list"
  }
}

run "genesis_apply_manifests_reach_the_control_plane" {
  command = plan

  variables {
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20-extra-manifest.yaml"
        content = "kind: Cluster\nname: bharat-extra\n"
      }
    ]
  }

  assert {
    condition     = module.control_plane.genesis_apply_manifest_paths == ["/opt/kube-compute/manifests/20-extra-manifest.yaml"]
    error_message = "a genesis_apply_manifests entry set on this module must reach the control plane"
  }
}

# The wrapper rejects the same bad paths node-bootstrap does, at the input.

run "genesis_apply_manifests_rejects_whitespace_in_a_path" {
  command = plan

  variables {
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20 extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_relative_path" {
  command = plan

  variables {
    genesis_apply_manifests = [
      {
        path    = "manifests/20-extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_dotdot_segment" {
  command = plan

  variables {
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/../../etc/20-extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_path_outside_the_directory" {
  command = plan

  variables {
    genesis_apply_manifests = [
      {
        path    = "/etc/20-extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}
