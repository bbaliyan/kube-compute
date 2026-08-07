# SPDX-License-Identifier: Apache-2.0
# Guards the kube-image template-clone path for worker pools: always a FULL
# clone, no stock-image import alongside it, exactly one image source.
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
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
  cluster_name         = "bharat"
  k8s_version          = "v1.36.2+rke2r1"
  proxmox_node         = "pve"
  vm_cores             = 2
  vm_memory_mb         = 4096
  vm_disk_gb           = 30
  desired_count        = 2
  registration_address = "192.168.1.5"
  cluster_agent_token  = "agent-secret-abc123"
  cluster_ipset_name   = "kube-compute-bharat-cluster"
}

run "template_clone_is_always_a_full_clone" {
  command = plan
  variables {
    proxmox_template_vm_id = 9000
    os_image_url           = null
    os_image_file_name     = null
  }

  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : length(vm.clone) == 1
    ])
    error_message = "a supplied proxmox_template_vm_id must produce exactly one clone block per worker"
  }
  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : vm.clone[0].full == true
    ])
    error_message = "full must be true on every clone — a linked clone makes every worker permanently depend on the kube-image template, which breaks the moment prune-images.sh deletes it"
  }
  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : vm.clone[0].vm_id == 9000
    ])
    error_message = "every worker's clone block must reference the supplied template VM ID"
  }
  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : vm.disk[0].import_from == null
    ])
    error_message = "a cloned worker must not also import a stock image"
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
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : length(vm.clone) == 0
    ])
    error_message = "the stock-image path must create no clone block — kube-image stays opt-in"
  }
}

run "two_image_sources_at_once_is_rejected" {
  command = plan
  variables {
    proxmox_template_vm_id = 9000
    os_image_url           = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name     = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }

  expect_failures = [proxmox_virtual_environment_vm.worker]
}

run "no_image_source_at_all_is_rejected" {
  command = plan
  variables {
    proxmox_template_vm_id = null
    os_image_url           = null
    os_image_file_name     = null
  }

  expect_failures = [proxmox_virtual_environment_vm.worker]
}

run "file_id_stock_image_path_creates_no_clone_block" {
  command = plan
  variables {
    proxmox_template_vm_id = null
    os_image_url           = null
    os_image_file_name     = null
    os_image_file_id       = "local:iso/almalinux-10.qcow2"
  }

  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : length(vm.clone) == 0
    ])
    error_message = "the os_image_file_id path must create no clone block — kube-image stays opt-in"
  }
  assert {
    condition = alltrue([
      for k, vm in proxmox_virtual_environment_vm.worker : vm.disk[0].import_from == "local:iso/almalinux-10.qcow2"
    ])
    error_message = "os_image_file_id must be wired straight to the disk's import_from when it is the sole image source"
  }
}

run "template_and_file_id_at_once_is_rejected" {
  command = plan
  variables {
    proxmox_template_vm_id = 9000
    os_image_url           = null
    os_image_file_name     = null
    os_image_file_id       = "local:iso/almalinux-10.qcow2"
  }

  expect_failures = [proxmox_virtual_environment_vm.worker]
}

run "url_and_file_id_at_once_is_rejected" {
  command = plan
  variables {
    proxmox_template_vm_id = null
    os_image_url           = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name     = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
    os_image_file_id       = "local:iso/almalinux-10.qcow2"
  }

  expect_failures = [proxmox_virtual_environment_vm.worker]
}
