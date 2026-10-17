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
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

variables {
  cluster_name        = "app-red"
  pool_name           = "workers"
  proxmox_node        = "pve"
  vm_cores            = 2
  vm_memory_mb        = 4096
  vm_disk_gb          = 30
  desired_count       = 2
  cluster_agent_token = "agent-secret-abc123"
  cluster_domain      = "red.lan"
  dns_server_address  = "192.168.1.53"
  tsig_key_name       = "kube-compute"
  tsig_key_secret     = "ZmFrZXNlY3JldA=="
  os_image_url        = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name  = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "unset_template_keeps_the_names" {
  command = plan

  assert {
    condition     = toset([for vm in values(proxmox_virtual_environment_vm.worker) : vm.name]) == toset(["app-red-workers-0", "app-red-workers-1"])
    error_message = "unset, workers must keep their names"
  }
  assert {
    condition     = toset(keys(output.worker_node_refs)) == toset(["app-red-workers-0", "app-red-workers-1"])
    error_message = "unset, worker_node_refs must keep its keys: got ${jsonencode(keys(output.worker_node_refs))}"
  }
}

run "template_names_every_worker" {
  command = plan

  variables {
    node_name_template = "wk-red-{number}"
  }

  assert {
    condition     = toset([for vm in values(proxmox_virtual_environment_vm.worker) : vm.name]) == toset(["wk-red-01", "wk-red-02"])
    error_message = "workers must be numbered from 01"
  }
  assert {
    condition     = toset(keys(output.worker_node_refs)) == toset(["wk-red-01", "wk-red-02"])
    error_message = "worker_node_refs must be keyed by the new names: got ${jsonencode(keys(output.worker_node_refs))}"
  }
}

run "template_without_number_is_rejected" {
  command = plan

  variables {
    node_name_template = "wk-red"
  }

  expect_failures = [var.node_name_template]
}

run "no_boot_scripts_leaves_plain_cloud_config" {
  command = plan

  assert {
    condition = alltrue([
      for snippet in values(proxmox_virtual_environment_file.node_init) :
      startswith(snippet.source_raw[0].data, "#cloud-config")
    ])
    error_message = "with no boot_scripts the snippet must stay a plain cloud-config"
  }
}

run "boot_scripts_run_first_on_every_worker_with_its_name" {
  command = plan

  variables {
    node_name_template = "wk-red-{number}"
    boot_scripts       = ["echo one", "echo two"]
  }

  assert {
    condition = alltrue([
      for snippet in values(proxmox_virtual_environment_file.node_init) :
      startswith(snippet.source_raw[0].data, "Content-Type: multipart/mixed")
      && length(regexall("(?m)^echo (one|two)$", snippet.source_raw[0].data)) == 2
      && strcontains(snippet.source_raw[0].data, "NODE_ROLE='worker'")
    ])
    error_message = "every worker must get both scripts, as a worker, ahead of its cloud-config"
  }
  assert {
    condition     = strcontains(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data, "NODE_NAME='wk-red-02'")
    error_message = "a script must see the worker's own name"
  }
}
