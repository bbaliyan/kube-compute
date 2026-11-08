# SPDX-License-Identifier: Apache-2.0
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

# An apply would otherwise run nsupdate against the test's DNS server. Overriding
# the resource is not enough: its provisioners still run.
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
    condition     = length(proxmox_virtual_environment_vm.control_plane) == 1
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
  # apply (not plan): every node's rendered cloud-init payload now embeds
  # random_password's result, which is unknown at plan time — the hostname
  # uniqueness assertions below need the actual rendered strings.
  command = apply
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
    condition     = length(proxmox_virtual_environment_vm.control_plane) == 3
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
      for k, v in { for k, v in proxmox_virtual_environment_file.node_init : k => v if k != "0" } :
      yamldecode(v.source_raw[0].data).hostname != yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).hostname
    ])
    error_message = "every additional control-plane node's cloud-init payload must set a hostname different from the genesis node's — rke2/kubelet default the registered Kubernetes node name to the OS hostname, so a collision makes every kubelet register as the same node, silently clobbering each other"
  }
  assert {
    condition = length(distinct([
      for k, v in { for k, v in proxmox_virtual_environment_file.node_init : k => v if k != "0" } :
      yamldecode(v.source_raw[0].data).hostname
    ])) == length(proxmox_virtual_environment_file.node_init) - 1
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
    condition     = length(proxmox_virtual_environment_vm.control_plane) == 3
    error_message = "control_plane_count = 3 over DHCP must still create exactly 2 additional control-plane VMs"
  }
}

# apply, not plan: the rendered payload embeds random_password's result, which is
# unknown at plan time.
run "single_node_genesis_has_no_probe_address" {
  command = apply

  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "REJOIN_PROBE_ADDRESSES=''") && strcontains(base64decode(f.content), "REGISTRATION_ADDRESS=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a single-node genesis has no peer to rejoin, so its node.env must leave REJOIN_PROBE_ADDRESSES and REGISTRATION_ADDRESS empty"
  }
}

run "ha_genesis_probes_every_static_peer" {
  command = apply
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
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "REJOIN_PROBE_ADDRESSES='192.168.1.11 192.168.1.12'") && strcontains(base64decode(f.content), "REGISTRATION_ADDRESS=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a 3-node genesis must probe both other control-plane nodes, in order: a replaced genesis points its own join name back at itself, and one peer may be down"
  }
  assert {
    condition = alltrue([
      for k, v in { for k, v in proxmox_virtual_environment_file.node_init : k => v if k != "0" } : anytrue([
        for f in yamldecode(v.source_raw[0].data).write_files :
        strcontains(base64decode(f.content), "REGISTRATION_ADDRESS='genesis.bharat.example.com'")
        if f.path == "/opt/kube-compute/node.env"
      ])
    ])
    error_message = "the other control-plane nodes must still join through the genesis join name"
  }
  assert {
    condition = alltrue([
      for k, v in { for k, v in proxmox_virtual_environment_file.node_init : k => v if k != "0" } : anytrue([
        for f in yamldecode(v.source_raw[0].data).write_files :
        strcontains(base64decode(f.content), "REJOIN_PROBE_ADDRESSES=''")
        if f.path == "/opt/kube-compute/node.env"
      ])
    ])
    error_message = "only genesis probes for a live cluster; the other control-plane nodes always join"
  }
}

run "five_node_genesis_probes_the_other_four" {
  command = apply
  variables {
    control_plane_count        = 5
    control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24", "192.168.1.13/24", "192.168.1.14/24"]
    cluster_domain             = "example.com"
    cluster_network_cidr       = "192.168.1.0/24"
    vm_gateway                 = "192.168.1.1"
    dns_server_address         = "192.168.1.53"
    tsig_key_name              = "kube-compute"
    tsig_key_secret            = "ZmFrZXNlY3JldA=="
  }

  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "REJOIN_PROBE_ADDRESSES='192.168.1.11 192.168.1.12 192.168.1.13 192.168.1.14'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a 5-node genesis must probe all four other control-plane nodes, and not its own address"
  }
}

run "ha_genesis_over_dhcp_has_no_probe_address" {
  command = apply
  variables {
    control_plane_count  = 3
    cluster_domain       = "example.com"
    cluster_network_cidr = "192.168.1.0/24"
    dns_server_address   = "192.168.1.53"
    tsig_key_name        = "kube-compute"
    tsig_key_secret      = "ZmFrZXNlY3JldA=="
  }

  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "REJOIN_PROBE_ADDRESSES=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "over DHCP no peer IP is known before genesis exists, so genesis must not carry a probe address"
  }
}
