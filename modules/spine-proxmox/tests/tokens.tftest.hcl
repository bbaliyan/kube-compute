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

run "server_and_agent_tokens_distinct_and_embedded_via_cloud_init" {
  command = apply
  variables {
    cluster_name               = "bharat"
    k8s_version                = "v1.36.1+k3s1"
    proxmox_node               = "pve"
    vm_cores                   = 4
    vm_memory_mb               = 8192
    vm_disk_gb                 = 50
    control_plane_ip_addresses = null
    allowed_ingress_cidrs      = ["192.168.1.0/24"]
    os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }

  assert {
    condition     = nonsensitive(random_password.server_token.result) != nonsensitive(random_password.agent_token.result)
    error_message = "server and agent tokens must be distinct"
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "--agent-token ${nonsensitive(random_password.agent_token.result)}")
    error_message = "the genesis node must be configured to accept exactly the agent token exposed via cluster_agent_token"
  }
  assert {
    condition     = nonsensitive(output.cluster_agent_token) == nonsensitive(random_password.agent_token.result)
    error_message = "cluster_agent_token output must be the agent token (delivered via cloud-init, not a secret store)"
  }
}
