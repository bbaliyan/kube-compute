# SPDX-License-Identifier: Apache-2.0
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.110"
    }
  }
}

provider "proxmox" {
  endpoint = "https://pve.example.internal:8006/"
  insecure = false
}

module "pool" {
  source = "../.."

  cluster_name  = "cluster1"
  proxmox_node  = "pve"
  vm_cores      = 4
  vm_memory_mb  = 8192
  vm_disk_gb    = 60
  desired_count = 2
  # Hardcoded here since this example shows the pool in isolation with no spine
  # module instantiated. Real consumers should wire this to the spine's own
  # output instead of duplicating the literal: spine_k8s_version = module.spine.k8s_version
  spine_k8s_version    = "v1.36.1+k3s1"
  registration_address = "192.168.1.5"
  cluster_agent_token  = "REPLACE_WITH_SPINE_OUTPUT"
  cluster_ipset_name   = "kube-node-cluster1-cluster"
  os_image_url         = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name   = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}
