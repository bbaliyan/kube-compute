# SPDX-License-Identifier: Apache-2.0
# random_string is a real (unmocked) resource whose computed attributes are
# genuinely unknown at plan time for a not-yet-created resource (standard
# Terraform/OpenTofu behavior, not specific to this provider). Since
# local.kv_name derives from random_string.kv_suffix.result, the
# KV-name-length assertion below needs that value known at plan time, so the
# random provider is mocked too. Note: `name` on azurerm_key_vault is a
# non-computed config-derived field — OpenTofu's test mocking rejects
# overriding it directly — so instead we pin random_string's result and let
# local.kv_name compute normally from real config.
mock_provider "random" {
  # Pin the suffix to its real 6-character width so the KV-name-length
  # assertion below reflects the actual 18+6=24 guarantee, not an
  # auto-generated placeholder of arbitrary length.
  mock_resource "random_string" {
    defaults = { result = "abc123" }
  }
}

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id = "00000000-0000-0000-0000-000000000001"
      object_id = "00000000-0000-0000-0000-000000000002"
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
  mock_resource "azurerm_application_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/applicationSecurityGroups/asg-bharat-cluster" }
  }
}

run "key_vault_holds_agent_token_not_server_token" {
  command = plan
  variables {
    cluster_name        = "bharat"
    resource_group_name = "rg-k8s"
    location            = "eastus"
  }
  assert {
    condition     = azurerm_key_vault.cluster.rbac_authorization_enabled == true
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
