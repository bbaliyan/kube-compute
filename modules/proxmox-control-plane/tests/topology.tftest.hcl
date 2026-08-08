# SPDX-License-Identifier: Apache-2.0
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

variables {
  cluster_name          = "bharat"
  k8s_version           = "v1.36.2+rke2r1"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  os_image_url          = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name    = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  cluster_token         = "test-cluster-token-0123456789"
  cluster_agent_token   = "test-agent-token-0123456789"
  cluster_ipset_name    = "kube-compute-bharat-cluster"
  etcd_ipset_name       = "kube-compute-bharat-etcd"
}

run "single_node_no_endpoint" {
  command = plan

  # NOTE: registration_address is no longer an output — Task 2 of this effort
  # intentionally removed it since nothing outside this module consumes it
  # anymore (it's now purely local.registration_address, wired internally into
  # module.node_bootstrap_additional's own input). This assertion's coverage
  # is no longer expressible via a module output and was removed rather than
  # replaced.
  assert {
    condition     = length(proxmox_virtual_environment_vm.control_plane_additional) == 0
    error_message = "control_plane_count = 1 must create no additional control-plane VMs"
  }
}

run "invalid_control_plane_count_rejected" {
  command = plan
  variables {
    control_plane_count        = 2
    control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24"]
    cluster_domain             = "example.com"
    vm_gateway                 = "192.168.1.1"
  }
  expect_failures = [var.control_plane_count]
}

run "ha_control_plane_creates_n_minus_1_additional_vms" {
  command = plan
  variables {
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
    condition     = length(proxmox_virtual_environment_vm.control_plane_additional) == 2
    error_message = "control_plane_count = 3 must create exactly 2 additional control-plane VMs"
  }
  # NOTE: registration_address is no longer an output — Task 2 of this effort
  # intentionally removed it since nothing outside this module consumes it
  # anymore (it's now purely local.registration_address, wired internally into
  # module.node_bootstrap_additional's own input). This assertion's coverage
  # is no longer expressible via a module output and was removed rather than
  # replaced.
  assert {
    condition = alltrue([
      for k, v in proxmox_virtual_environment_file.node_init_additional :
      yamldecode(v.source_raw[0].data).hostname != yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).hostname
    ])
    error_message = "every additional control-plane node's cloud-init payload must set a hostname different from the genesis node's — rke2/kubelet default the registered Kubernetes node name to the OS hostname, so a collision makes every kubelet register as the same node, silently clobbering each other"
  }
  assert {
    condition = length(distinct([
      for k, v in proxmox_virtual_environment_file.node_init_additional :
      yamldecode(v.source_raw[0].data).hostname
    ])) == length(proxmox_virtual_environment_file.node_init_additional)
    error_message = "additional control-plane nodes must each get a distinct hostname from one another too, not just from genesis"
  }
  assert {
    condition     = length(output.control_plane_node_refs) == 3
    error_message = "control_plane_node_refs must have one entry per control-plane node"
  }
}

run "ha_control_plane_over_dhcp" {
  command = plan
  variables {
    control_plane_count  = 3
    cluster_domain       = "example.com"
    cluster_network_cidr = "192.168.1.0/24"
    dns_server_address   = "192.168.1.53"
    tsig_key_name        = "kube-compute"
    tsig_key_secret      = "ZmFrZXNlY3JldA=="
    # control_plane_ip_addresses / vm_gateway left unset: DHCP for every node,
    # including the additional (non-genesis) control-plane VMs — regression
    # coverage for the "Invalid index" plan-time crash this combination
    # previously hit (control_plane_additional indexed the static-only
    # network_data map unconditionally, which is empty under DHCP).
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.control_plane_additional) == 2
    error_message = "control_plane_count = 3 over DHCP must still create exactly 2 additional control-plane VMs"
  }
}
