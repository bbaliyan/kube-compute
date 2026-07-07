# SPDX-License-Identifier: Apache-2.0
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
}

module "spine" {
  source = "../../../spine-azure"

  cluster_name          = "devcluster"
  resource_group_name   = "rg-devcluster"
  location              = "eastus"
  vnet_name             = "vnet-devcluster"
  subnet_name           = "snet-k8s"
  vm_size               = "Standard_D4s_v3"
  admin_ssh_public_key  = "ssh-rsa AAAA... replace-with-your-key"
  allowed_ingress_cidrs = ["203.0.113.0/24"]
  control_plane_count   = 3
}

module "workers_zone1" {
  source = "../.."

  cluster_name            = "devcluster"
  resource_group_name     = "rg-devcluster"
  location                = "eastus"
  vnet_name               = "vnet-devcluster"
  subnet_name             = "snet-k8s"
  vm_size                 = "Standard_D4s_v3"
  admin_ssh_public_key    = "ssh-rsa AAAA... replace-with-your-key"
  zone                    = "1"
  desired_count           = 2
  spine_k8s_version       = module.spine.k8s_version
  registration_address    = module.spine.registration_address
  key_vault_id            = module.spine.key_vault_id
  key_vault_name          = module.spine.key_vault_name
  agent_token_secret_name = module.spine.agent_token_secret_name
  cluster_asg_id          = module.spine.cluster_asg_id
}
