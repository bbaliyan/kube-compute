# SPDX-License-Identifier: Apache-2.0
# Pins the rendered user data of every control-plane node to a known hash, so a
# refactor of how it is built cannot change what a node boots with. The tokens
# are fixed, and the addresses are static, so the render is stable.
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
  cluster_name               = "demo"
  proxmox_node               = "pve"
  vm_cores                   = 4
  vm_memory_mb               = 8192
  vm_disk_gb                 = 50
  control_plane_count        = 3
  control_plane_ip_addresses = ["192.168.1.10/24", "192.168.1.11/24", "192.168.1.12/24"]
  cluster_domain             = "example.test"
  cluster_network_cidr       = "192.168.1.0/24"
  vm_gateway                 = "192.168.1.1"
  allowed_ingress_cidrs      = ["192.168.1.0/24"]
  proxmox_template_vm_id     = 9000
  dns_server_address         = "192.168.1.53"
  tsig_key_name              = "kube-compute"
  tsig_key_secret            = "ZmFrZXNlY3JldA=="
  boot_scripts               = ["echo one", "echo two"]
}

run "user_data_is_unchanged" {
  command = apply

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "d663d38abae8cb4644f4a0e65abe22b2abd9791901ef4f54d23abd28b86ae92e"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "27ca1e1d4aee887cc532bb43b478d647562a4f452a3cf2a7e2546b6e9fc72d8b"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["2"].source_raw[0].data) == "8a7170af1ef15164e2dac0c91debceea2b30a898545d9d34168c32724b83db3a"
    error_message = "the third node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["2"].source_raw[0].data)), "?")}"
  }
}

run "user_data_without_boot_scripts_is_unchanged" {
  command = apply

  variables {
    boot_scripts = []
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "87fbd77d75ac561725838f6594fb02df3408661dbe26dcf007b74b76fd189bc8"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "54f210f3d10e4aa3a9b4debc7844dc68b1d4fe1c8ad510d8db5113b7c5cc62f9"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }
}
