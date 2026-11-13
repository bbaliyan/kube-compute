# SPDX-License-Identifier: Apache-2.0
# Pins the rendered user data of every control-plane node to a known hash, so a
# refactor of how it is built cannot change what a node boots with. The tokens
# and the mocked addresses are fixed, so the render is stable.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/demo.yaml" }
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
  outputs = { fqdn = "api.demo.example.test.", record_created = true }
}

override_module {
  target  = module.dns_registration_wildcard
  outputs = { fqdn = "*.demo.example.test.", record_created = true }
}

override_resource {
  target = random_password.server_token
  values = { result = "server-token-for-the-render-test" }
}

override_resource {
  target = random_password.agent_token
  values = { result = "agent-token-for-the-render-test" }
}

variables {
  cluster_name           = "demo"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  control_plane_count    = 3
  cluster_domain         = "example.test"
  cluster_network_cidr   = "192.168.1.0/24"
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  proxmox_template_vm_id = 9000
  dns_server_address     = "192.168.1.53"
  tsig_key_name          = "kube-compute"
  tsig_key_secret        = "ZmFrZXNlY3JldA=="
}

run "user_data_is_unchanged" {
  command = apply

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "d09ca02fec780ebc60a38c560be4e59ebad4ef0abc5343aedf3131717929a13f"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "94b15e0955a45539b7bb205257f3d36cfcd21ae9f041b143f2f33b8036b56031"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["2"].source_raw[0].data) == "f8a0dad3ef9f92cd7be56cafb1b191be0f74505c2726d02cbd8b8b252eb10e93"
    error_message = "the third node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["2"].source_raw[0].data)), "?")}"
  }
}

