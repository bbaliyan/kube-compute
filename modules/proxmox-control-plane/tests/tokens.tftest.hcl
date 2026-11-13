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

run "server_and_agent_tokens_distinct_and_embedded_via_cloud_init" {
  # apply (not plan): random_password's result is unknown at plan time — this
  # run needs the actual generated values to assert they made it into the
  # rendered cloud-init payload unchanged. Every other resource in this module
  # is either a mocked Proxmox resource or an equally apply-safe local render,
  # so nothing here talks to a real API.
  command = apply
  variables {
    cluster_name           = "example"
    proxmox_node           = "pve"
    vm_cores               = 4
    vm_memory_mb           = 8192
    vm_disk_gb             = 50
    allowed_ingress_cidrs  = ["192.168.1.0/24"]
    proxmox_template_vm_id = 9000
  }

  assert {
    condition     = output.cluster_token != output.cluster_agent_token
    error_message = "the server and agent tokens must be generated as distinct values"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "token: ${jsonencode(output.cluster_token)}\n") &&
      strcontains(base64decode(f.content), "agent-token: ${jsonencode(output.cluster_agent_token)}\n")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "the genesis node's payload must carry both the server and the agent join token, matching this module's own generated tokens"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      f.permissions == "0600"
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "the join tokens must land in a 0600 file on the node, never a world-readable one"
  }
  assert {
    condition = alltrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init["0"].source_raw[0].data).write_files :
      !strcontains(base64decode(f.content), "ansible")
    ])
    error_message = "no part of the payload may reference Ansible — this module no longer runs any playbook against the node"
  }
}
