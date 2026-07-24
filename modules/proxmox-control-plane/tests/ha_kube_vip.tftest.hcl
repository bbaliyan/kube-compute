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

# NOTE: kube_vip_manifest_renders_with_configured_vip used to live here, asserting on
# the `rendered_cloud_init` output for the kube-vip DaemonSet manifest, VIP address,
# and manifest path. That output no longer exists — the kube-vip manifest is now
# handed to `node-bootstrap` as one of `extra_server_manifests`, rendered by Ansible
# at real-apply time rather than into a Terraform-visible string, and this module's
# apply can no longer complete in a sandboxed/CI environment (node-bootstrap's
# local-exec genuinely invokes `ansible-playbook`). There is currently no automated
# test coverage for kube-vip manifest content (DaemonSet kind, VIP address,
# manifest path). See rke2-ansible-bootstrap Ticket 14's resolution notes.
