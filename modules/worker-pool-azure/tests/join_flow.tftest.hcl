# SPDX-License-Identifier: Apache-2.0
mock_provider "azurerm" {
  mock_data "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/nsg-bharat-worker" }
  }
  mock_resource "azurerm_linux_virtual_machine_scale_set" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-bharat-worker"
      identity = { principal_id = "00000000-0000-0000-0000-000000000099", tenant_id = "00000000-0000-0000-0000-000000000001" }
    }
  }
  mock_resource "azurerm_role_assignment" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000004" }
  }
}

run "worker_fetches_agent_token_via_imds_and_key_vault_rest_not_ssm" {
  command = apply
  variables {
    cluster_name            = "bharat"
    k8s_version             = "v1.36.1+k3s1"
    spine_k8s_version       = "v1.36.1+k3s1"
    resource_group_name     = "rg-k8s"
    location                = "eastus"
    vnet_name               = "vnet-main"
    subnet_name             = "snet-k8s"
    vm_size                 = "Standard_D2s_v3"
    admin_ssh_public_key    = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-compute-test"
    zone                    = "1"
    desired_count           = 2
    registration_address    = "10.0.1.100"
    key_vault_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.KeyVault/vaults/kvbharat123456"
    key_vault_name          = "kvbharat123456"
    agent_token_secret_name = "agent-token"
    cluster_asg_id          = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/applicationSecurityGroups/asg-bharat-cluster"
  }
  assert {
    condition     = strcontains(nonsensitive(module.bootstrap.cloud_init), "169.254.169.254/metadata/identity/oauth2/token")
    error_message = "every worker's cloud-init must fetch its OAuth token from Azure IMDS, not az CLI"
  }
  assert {
    condition     = strcontains(nonsensitive(module.bootstrap.cloud_init), "kvbharat123456.vault.azure.net/secrets/agent-token")
    error_message = "every worker's cloud-init must fetch the agent token from this cluster's own Key Vault secret"
  }
  assert {
    condition     = !strcontains(nonsensitive(module.bootstrap.cloud_init), "aws ssm")
    error_message = "an Azure worker must never reference AWS SSM"
  }
  assert {
    condition     = !strcontains(nonsensitive(module.bootstrap.cloud_init), "az keyvault")
    error_message = "the fetch command must use raw curl+IMDS, not the az CLI (not guaranteed present on the image)"
  }
  assert {
    condition     = azurerm_linux_virtual_machine_scale_set.worker.instances == 2
    error_message = "desired_count = 2 must create a VMSS with instances = 2"
  }
  assert {
    condition     = contains(azurerm_linux_virtual_machine_scale_set.worker.zones, "1")
    error_message = "the VMSS must be pinned to the single configured zone"
  }
  assert {
    condition     = azurerm_role_assignment.agent_token_read.role_definition_name == "Key Vault Secrets User"
    error_message = "the worker identity must be granted Key Vault Secrets User, not a broader role"
  }
  assert {
    condition     = azurerm_role_assignment.agent_token_read.scope == "${var.key_vault_id}/secrets/${var.agent_token_secret_name}"
    error_message = "the role assignment must be scoped to the individual secret, not the whole vault"
  }
}
