# SPDX-License-Identifier: Apache-2.0
# Minimal node-azure usage. Replace values for your environment.
# For `tofu plan` illustration only (no backend wired).

provider "azurerm" {
  features {}
  # subscription_id = "00000000-0000-0000-0000-000000000000"
  # Or set ARM_SUBSCRIPTION_ID in the environment.
}

module "cluster" {
  source = "../.."

  cluster_name = "my-cluster"
  k8s_version  = "v1.36.1+k3s1"

  resource_group_name = "rg-k8s"
  location            = "eastus"
  vnet_name           = "vnet-main"
  subnet_name         = "snet-k8s"

  vm_size = "Standard_D4s_v3"

  # Azure requires an SSH public key even though port 22 is blocked by the NSG.
  admin_ssh_public_key = file("~/.ssh/id_rsa.pub")

  # Who can reach the cluster ports (K3s API, HTTPS, HTTP).
  allowed_ingress_cidrs = ["10.0.0.0/8"]

  # Static IP is strongly recommended — DHCP makes DNS unreliable and cluster_ip
  # is unavailable at plan time.
  vm_private_ip = "10.0.1.10"

  # Optional: set a domain to populate wildcard_dns_name and cluster_fqdn.
  # When dns_zone_resource_group is also set, a wildcard A record is created automatically.
  # cluster_domain          = "example.com"
  # dns_zone_resource_group = "rg-dns"

  # Optional: registry mirror, trusted CA, GitOps.
  # registry_mirror_url      = "https://harbor.example.com"
  # gitops_platform_repo_url = "https://github.com/me/kube-platform.git"
}

output "register_this_dns" {
  description = "Add a wildcard A record pointing at cluster_ip. Null when no cluster_domain is set."
  value = {
    name = module.cluster.wildcard_dns_name
    ip   = module.cluster.cluster_ip
  }
}

output "control_plane" {
  description = "Use bootstrap_status_ref for out-of-band access via az vm run-command invoke."
  value = {
    bootstrap_status_ref = module.cluster.bootstrap_status_ref
    resource_group_name  = module.cluster.resource_group_name
    location             = module.cluster.location
  }
}
