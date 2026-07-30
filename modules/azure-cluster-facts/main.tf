# SPDX-License-Identifier: Apache-2.0
module "cluster_facts" {
  source = "../cluster-facts"

  k8s_version = var.k8s_version

  platform_enabled           = var.platform_enabled
  platform_repo_url_override = var.platform_repo_url_override
  platform_revision_override = var.platform_revision_override
  workloads_repo_url         = var.workloads_repo_url
  workloads_revision         = var.workloads_revision
  workloads_path             = var.workloads_path
}

data "azurerm_client_config" "current" {}

locals {
  # Kv name: 24-char Azure limit, globally unique — 18 chars of cluster_name (hyphens
  # stripped) + a 6-char random suffix = 24 exactly. Identical convention to
  # azure-control-plane's own (now-removed) kv_name local.
  kv_name = "${substr("kv${replace(var.cluster_name, "-", "")}", 0, 18)}${random_string.kv_suffix.result}"

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })
}

resource "random_string" "kv_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---- Key Vault: RBAC authorization, agent token only ----
# Moved here (out of azure-control-plane) because azure-node-pool's own role assignment
# (already correct, unchanged — see this plan's architecture note) is scoped under this
# vault at the individual-secret level, which needs the vault and secret to already
# exist — the same "real resource ID, not a name" hard-dependency shape as AWS's
# security group (ticket 03 of the parallelize-multinode-apply wayfinder map).
resource "azurerm_key_vault" "cluster" {
  name                       = local.kv_name
  resource_group_name        = var.resource_group_name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  tags                       = local.common_tags
}

# RBAC authorization grants nothing implicitly — the executing principal needs an
# explicit role to write the secret below. NOTE: Azure role assignments are eventually
# consistent (documented propagation delay of up to a few minutes); a first apply
# immediately after vault creation may need to be re-run if the secret write races this
# assignment — this caveat is unchanged from azure-control-plane's original comment,
# just relocated.
resource "azurerm_role_assignment" "kv_admin_self" {
  scope                = azurerm_key_vault.cluster.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "agent_token" {
  name         = "agent-token"
  value        = module.cluster_facts.agent_token
  key_vault_id = azurerm_key_vault.cluster.id
  tags         = local.common_tags

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

# ---- Cluster Application Security Group ----
# Moved here (out of azure-control-plane) because azure-node-pool's worker NICs join
# this by real id (azurerm_network_interface_application_security_group_association),
# a hard dependency confirmed in ticket 03 — the same shape as AWS's security group.
resource "azurerm_application_security_group" "cluster" {
  name                = "asg-${var.cluster_name}-cluster"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}
