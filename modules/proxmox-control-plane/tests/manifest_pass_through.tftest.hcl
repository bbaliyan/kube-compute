# SPDX-License-Identifier: Apache-2.0
# Guards the extra_server_manifests pass-through: this
# module is a pure forward of these variables into its own genesis module
# "node_bootstrap" call, the same pattern every other node-bootstrap variable
# already gets here.
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
  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  proxmox_template_vm_id = 9000
}

run "extra_server_manifests_thread_through_to_node_bootstrap" {
  command = apply

  variables {
    extra_server_manifests = {
      "20-coredns-lan-forward.yaml" = "kind: HelmChartConfig\nname: rke2-coredns\n"
    }
  }

  assert {
    condition = contains(
      [for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files : f.path],
      "/opt/kube-compute/server-manifests/20-coredns-lan-forward.yaml"
    )
    error_message = "an extra_server_manifests entry passed to this module must reach its own genesis node_bootstrap call's write_files"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "kind: HelmChartConfig") &&
      strcontains(base64decode(f.content), "name: rke2-coredns")
      if f.path == "/opt/kube-compute/server-manifests/20-coredns-lan-forward.yaml"
    ])
    error_message = "the entry's content must be forwarded verbatim, unmodified by this module"
  }
}
