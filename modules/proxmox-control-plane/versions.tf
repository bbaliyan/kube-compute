# SPDX-License-Identifier: Apache-2.0
terraform {
  required_version = ">= 1.12.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.110"
    }
    dns = {
      source  = "hashicorp/dns"
      version = "~> 3.6"
    }
    # Used transitively by ../node-bootstrap to render the Cilium/Argo CD
    # genesis manifests. Declared explicitly so `tofu test`'s
    # mock_provider "external" has a provider to bind to here.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
