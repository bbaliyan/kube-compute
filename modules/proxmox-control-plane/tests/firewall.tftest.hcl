# SPDX-License-Identifier: Apache-2.0
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

run "cluster_ipset_created_and_referenced" {
  command = plan
  variables {
    cluster_name           = "example"
    proxmox_node           = "pve"
    vm_cores               = 4
    vm_memory_mb           = 8192
    vm_disk_gb             = 50
    control_plane_count    = 3
    cluster_domain         = "example.com"
    cluster_network_cidr   = "192.168.1.0/24"
    allowed_ingress_cidrs  = ["192.168.1.0/24"]
    proxmox_template_vm_id = 9000
    dns_server_address     = "192.168.1.53"
    tsig_key_name          = "kube-compute"
    tsig_key_secret        = "ZmFrZXNlY3JldA=="
  }

  assert {
    condition     = proxmox_virtual_environment_firewall_ipset.cluster.name == "kube-compute-example-cluster"
    error_message = "cluster ipset must be named predictably so node pools can reference it by name"
  }
  assert {
    condition     = alltrue([for r in proxmox_virtual_environment_firewall_rules.control_plane["0"].rule : true if strcontains(coalesce(r.source, ""), "kube-compute-example-cluster") || contains(var.allowed_ingress_cidrs, coalesce(r.source, ""))])
    error_message = "every control-plane firewall rule's source must be the cluster ipset or an allowed ingress CIDR"
  }
  assert {
    condition = alltrue(concat(
      [proxmox_virtual_environment_vm.control_plane["0"].network_device[0].firewall],
      [for vm in [for k, v in proxmox_virtual_environment_vm.control_plane : v if k != "0"] : vm.network_device[0].firewall],
    ))
    error_message = "every control-plane NIC must enable the firewall, or Proxmox never enforces the rules above"
  }
}
