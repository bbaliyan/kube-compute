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
  argocd_manifest_url        = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256     = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
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
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "b63c0a8f8b542919b3612b0eef69fa151613dabd9f2a714c42684fe7d32dbea3"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "b62670ef362a3970a438f5a5de40831391ddf093e9cd8dd86cebf1421404648f"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["2"].source_raw[0].data) == "103fa8bb517ac53f8ded2bb38df2ef5560daefa8664b0cd177ec2cb746f465b5"
    error_message = "the third node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["2"].source_raw[0].data)), "?")}"
  }
}

run "user_data_without_boot_scripts_is_unchanged" {
  command = apply

  variables {
    boot_scripts = []
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data) == "3266a5cc6f75ec0562abdda92bbe3337e23333758b23309eeb6c686df05d293c"
    error_message = "the genesis user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data)), "?")}"
  }

  assert {
    condition     = sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data) == "48837d1ea9312a0d2c8cc13a0938f7797f8a6dbfeae52a99b8b2b8e0da2bcc05"
    error_message = "the second node user data must render as before: got ${try(nonsensitive(sha256(proxmox_virtual_environment_file.node_init["1"].source_raw[0].data)), "?")}"
  }
}
