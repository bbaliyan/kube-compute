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
mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = { manifest = "# mocked-helm-render" }
    }
  }
}

run "server_and_agent_tokens_distinct_and_embedded_via_cloud_init" {
  command = plan
  variables {
    cluster_name               = "bharat"
    k8s_version                = "v1.36.2+rke2r1"
    proxmox_node               = "pve"
    vm_cores                   = 4
    vm_memory_mb               = 8192
    vm_disk_gb                 = 50
    control_plane_ip_addresses = null
    allowed_ingress_cidrs      = ["192.168.1.0/24"]
    os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
    cluster_token              = "test-cluster-token-0123456789"
    cluster_agent_token        = "test-agent-token-0123456789"
    cluster_ipset_name         = "kube-compute-bharat-cluster"
    etcd_ipset_name            = "kube-compute-bharat-etcd"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "CLUSTER_TOKEN='test-cluster-token-0123456789'") &&
      strcontains(base64decode(f.content), "CLUSTER_AGENT_TOKEN='test-agent-token-0123456789'")
      if f.path == "/opt/kube-compute/secrets.env"
    ])
    error_message = "the genesis node's payload must carry both the server and the agent join token, and they must be distinct values"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files :
      f.permissions == "0600"
      if f.path == "/opt/kube-compute/secrets.env"
    ])
    error_message = "the join tokens must land in a 0600 file on the node, never a world-readable one"
  }
  assert {
    condition = alltrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files :
      !strcontains(base64decode(f.content), "ansible")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "the bootstrap payload must not reference Ansible — this module no longer runs any playbook against the node"
  }
}
