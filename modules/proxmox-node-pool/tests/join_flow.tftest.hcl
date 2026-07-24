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

run "worker_pool_wiring" {
  command = plan
  variables {
    cluster_name              = "bharat"
    k8s_version               = "v1.36.2+rke2r1"
    control_plane_k8s_version = "v1.36.2+rke2r1"
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

  # NOTE: two assertions used to live here, checking the now-removed
  # `rendered_cloud_init` output for the embedded agent-token fetch command and the
  # absence of an AWS SSM reference. The agent token now flows to node-bootstrap's
  # `agent_token_fetch_command` variable, which is merged into the local-exec
  # provisioner's `environment` block (not a trigger or any other plan/state-visible
  # attribute) — so there is no longer a Terraform-visible value to assert on for
  # this content. The "never references AWS SSM" property is true by construction
  # here (this module always sets ansible_connection_vars.ansible_connection = "ssh"),
  # but that input isn't re-exposed as an output either. See rke2-ansible-bootstrap
  # Ticket 14's resolution notes for this coverage gap.
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
