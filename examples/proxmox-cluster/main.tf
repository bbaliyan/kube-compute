# SPDX-License-Identifier: Apache-2.0
# A single-node cluster from a template VM. Every value is a placeholder.

terraform {
  required_version = ">= 1.12.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.122"
    }
  }
}

provider "proxmox" {
  endpoint = "https://pve.example.invalid:8006/"
}

module "cluster" {
  # From the registry: source = "bbaliyan/kube-compute/proxmox" and a version.
  source = "../../modules/proxmox-cluster"

  cluster_name           = "example"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  proxmox_template_vm_id = 9000
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
}
