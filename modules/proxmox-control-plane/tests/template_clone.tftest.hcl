# SPDX-License-Identifier: Apache-2.0
# Guards the kube-image template-clone path: cloning must always be a FULL
# clone (a linked clone leaves every node depending on a template that
# kube-image's own prune-images.sh will eventually delete), the disk must not
# also try to import a stock image, and exactly one of the three image sources
# may be set.
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
mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = { manifest = "# mocked-helm-render" }
    }
  }
}

variables {
  cluster_name          = "bharat"
  k8s_version           = "v1.36.2+rke2r1"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  cluster_token         = "test-cluster-token-0123456789"
  cluster_agent_token   = "test-agent-token-0123456789"
  cluster_ipset_name    = "kube-compute-bharat-cluster"
  etcd_ipset_name       = "kube-compute-bharat-etcd"
}

run "template_clone_is_always_a_full_clone" {
  command = plan
  variables {
    proxmox_template_vm_id = 9000
    os_image_url           = null
    os_image_file_name     = null
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.control_plane.clone) == 1
    error_message = "a supplied proxmox_template_vm_id must produce exactly one clone block"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.clone[0].vm_id == 9000
    error_message = "the clone block must reference the supplied template VM ID"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.clone[0].full == true
    error_message = "full must be true on every clone — a linked clone makes every node permanently depend on the kube-image template, which breaks the moment prune-images.sh deletes it"
  }
  assert {
    condition     = proxmox_virtual_environment_vm.control_plane.disk[0].import_from == null
    error_message = "a cloned VM must not also import a stock image — the clone already brings its own disk"
  }
  assert {
    condition     = length(proxmox_download_file.os_image) == 0
    error_message = "the template path must not download a stock cloud image"
  }
}

run "stock_image_path_still_creates_no_clone_block" {
  command = plan
  variables {
    proxmox_template_vm_id = null
    os_image_url           = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name     = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.control_plane.clone) == 0
    error_message = "the stock-image path must create no clone block — kube-image stays opt-in and kube-compute must keep working standalone"
  }
}

run "all_three_image_sources_at_once_is_rejected" {
  command = plan
  variables {
    proxmox_template_vm_id = 9000
    os_image_url           = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name     = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }

  expect_failures = [proxmox_virtual_environment_vm.control_plane]
}

run "no_image_source_at_all_is_rejected" {
  command = plan
  variables {
    proxmox_template_vm_id = null
    os_image_url           = null
    os_image_file_name     = null
  }

  expect_failures = [proxmox_virtual_environment_vm.control_plane]
}
