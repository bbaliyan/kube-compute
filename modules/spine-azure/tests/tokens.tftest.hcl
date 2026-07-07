# SPDX-License-Identifier: Apache-2.0
# random_string/random_password are real (unmocked) resources whose computed
# attributes are genuinely unknown at plan time for a not-yet-created resource
# (standard Terraform/OpenTofu behavior, not specific to this provider). Since
# local.kv_name derives from random_string.kv_suffix.result, the KV-name-length
# assertion below needs that value known at plan time, so the random provider
# is mocked too.
mock_provider "random" {}

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_data "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s"
    }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.KeyVault/vaults/kvbharat123456", vault_uri = "https://kvbharat123456.vault.azure.net/" }
  }
  mock_resource "azurerm_role_assignment" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000003" }
  }
  mock_resource "azurerm_key_vault_secret" {
    defaults = { id = "https://kvbharat123456.vault.azure.net/secrets/agent-token/abc123" }
  }
}

run "key_vault_holds_agent_token_not_server_token" {
  command = plan
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name              = "vnet-main"
    subnet_name            = "snet-k8s"
    vm_size                = "Standard_D4s_v3"
    admin_ssh_public_key    = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs  = ["10.0.0.0/8"]
  }
  assert {
    condition     = azurerm_key_vault.cluster.enable_rbac_authorization == true
    error_message = "Key Vault must use RBAC authorization, not access policies"
  }
  assert {
    condition     = azurerm_key_vault_secret.agent_token.name == "agent-token"
    error_message = "the agent token secret must be named 'agent-token'"
  }
  assert {
    condition     = length(azurerm_key_vault.cluster.name) <= 24
    error_message = "Key Vault names must be at most 24 characters"
  }
  assert {
    condition     = azurerm_role_assignment.kv_admin_self.role_definition_name == "Key Vault Secrets Officer"
    error_message = "the executing principal needs Key Vault Secrets Officer to write the secret under RBAC authorization"
  }
}
