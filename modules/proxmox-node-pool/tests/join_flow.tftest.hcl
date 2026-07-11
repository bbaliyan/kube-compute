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
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

run "worker_gets_agent_token_via_cloud_init_not_ssm" {
  command = apply
  variables {
    cluster_name              = "bharat"
    k8s_version               = "v1.36.1+k3s1"
    control_plane_k8s_version = "v1.36.1+k3s1"
    proxmox_node              = "pve"
    vm_cores                  = 2
    vm_memory_mb              = 4096
    vm_disk_gb                = 30
    desired_count             = 2
    registration_address      = "192.168.1.5"
    cluster_agent_token       = "agent-secret-abc123"
    cluster_ipset_name        = "kube-compute-bharat-cluster"
    os_image_url              = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name        = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }

  assert {
    condition     = alltrue([for k, ci in output.rendered_cloud_init : strcontains(nonsensitive(ci), "echo 'agent-secret-abc123'")])
    error_message = "every worker's cloud-init must embed the agent token directly via agent_token_fetch_command (Proxmox has no SSM equivalent)"
  }
  assert {
    condition     = alltrue([for k, ci in output.rendered_cloud_init : !strcontains(nonsensitive(ci), "aws ssm")])
    error_message = "a Proxmox worker must never reference AWS SSM"
  }
  assert {
    condition     = length(proxmox_virtual_environment_vm.worker) == 2
    error_message = "desired_count = 2 must create exactly 2 worker VMs"
  }
  assert {
    condition     = alltrue([for k, r in proxmox_virtual_environment_firewall_rules.worker : strcontains(coalesce(r.rule[0].source, ""), "kube-compute-bharat-cluster")])
    error_message = "every worker VM's firewall rule must reference the control plane's cluster ipset by name, never create its own"
  }
  assert {
    condition     = output.node_provider == "proxmox"
    error_message = "module must expose a node_provider output — kube-shell/kube-status/kube-start read it from terragrunt output to dispatch; without it they get literal JSON null and fail with \"unknown node_provider 'null'\" when run from a node-pool directory"
  }
}
