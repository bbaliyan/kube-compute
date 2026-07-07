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
  source = "../.."

  cluster_name          = "devcluster"
  resource_group_name   = "rg-devcluster"
  location              = "eastus"
  vnet_name             = "vnet-devcluster"
  subnet_name           = "snet-k8s"
  vm_size               = "Standard_D4s_v3"
  admin_ssh_public_key  = "ssh-rsa AAAA... replace-with-your-key"
  allowed_ingress_cidrs = ["203.0.113.0/24"]
}
