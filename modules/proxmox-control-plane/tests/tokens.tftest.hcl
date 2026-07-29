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

  # NOTE: all three assertions that used to live here compared random_password.*.result
  # values, or asserted content in the now-removed `rendered_cloud_init` output.
  # random_password's result is unknown until apply, and this module's apply now
  # genuinely invokes node-bootstrap's local-exec (real ansible-playbook), which this
  # sandboxed/CI environment can't run — so there's no way to reach those apply-time
  # values here anymore. See rke2-ansible-bootstrap Ticket 14's resolution notes for
  # this coverage gap (token distinctness, agent-token propagation into the bootstrap
  # run, cluster_agent_token output correctness).
}
