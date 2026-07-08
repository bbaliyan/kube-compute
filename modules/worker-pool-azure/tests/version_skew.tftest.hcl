# SPDX-License-Identifier: Apache-2.0
mock_provider "azurerm" {
  mock_data "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s" }
  }
  mock_resource "azurerm_linux_virtual_machine_scale_set" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-bharat-worker"
      identity = { principal_id = "00000000-0000-0000-0000-000000000099", tenant_id = "00000000-0000-0000-0000-000000000001" }
    }
  }
}

run "newer_pool_version_than_spine_rejected" {
  command = plan
  variables {
    cluster_name            = "bharat"
    k8s_version             = "v1.37.0+k3s1"
    spine_k8s_version       = "v1.36.1+k3s1"
    resource_group_name     = "rg-k8s"
    location                = "eastus"
    vnet_name               = "vnet-main"
    subnet_name             = "snet-k8s"
    vm_size                 = "Standard_D2s_v3"
    admin_ssh_public_key    = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-compute-test"
    zone                    = "1"
    registration_address    = "10.0.1.100"
    key_vault_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.KeyVault/vaults/kvbharat123456"
    key_vault_name          = "kvbharat123456"
    agent_token_secret_name = "agent-token"
    cluster_asg_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/applicationSecurityGroups/asg-bharat-cluster"
  }
  expect_failures = [azurerm_linux_virtual_machine_scale_set.worker]
}
