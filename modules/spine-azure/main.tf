# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../node-bootstrap/templates/cloud-init-ubuntu-2604.yaml.tpl")

  network_rg = coalesce(var.network_resource_group_name, var.resource_group_name)

  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  create_record = local.has_domain && var.dns_zone_resource_group != null

  control_plane_taint              = var.cluster_type == "dedicated_control_plane"
  effective_cni                    = var.cni != null ? var.cni : (var.control_plane_count > 1 ? "cilium" : "flannel")
  effective_etcd_snapshots_enabled = var.etcd_snapshots_enabled != null ? var.etcd_snapshots_enabled : var.control_plane_count > 1

  # Kv name: 24-char Azure limit, globally unique — 18 chars of cluster_name (hyphens
  # stripped; Key Vault names are alphanumeric-and-hyphen but a plain alnum body keeps this
  # simple) + a 6-char random suffix = 24 exactly.
  kv_name = "${substr("kv${replace(var.cluster_name, "-", "")}", 0, 18)}${random_string.kv_suffix.result}"

  # OS image: split a user-provided URN (Publisher:Offer:SKU:Version) or default to
  # Ubuntu 26.04 LTS gen2, same convention as node-azure.
  image_parts     = var.os_image_urn != null ? split(":", var.os_image_urn) : []
  image_publisher = var.os_image_urn != null ? local.image_parts[0] : "Canonical"
  image_offer     = var.os_image_urn != null ? local.image_parts[1] : "ubuntu-26_04-lts"
  image_sku       = var.os_image_urn != null ? local.image_parts[2] : "server-gen2"
  image_version   = var.os_image_urn != null ? local.image_parts[3] : "latest"

  # Null for control_plane_count = 1 (no registration endpoint — ADR 0003); the internal
  # Standard LB's dynamic private frontend IP otherwise (see Task 5).
  registration_address = var.control_plane_count == 1 ? null : try(azurerm_lb.control_plane[0].frontend_ip_configuration[0].private_ip_address, null)

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-node"
  })
}

# ---- Join-token flow: pre-generated so a spine + pool join in one apply pass ----
# Two tokens, least privilege: the server token grants joining etcd/control-plane (embedded
# directly into this spine's own node-bootstrap calls — control-plane nodes never fetch
# anything from Key Vault); the agent token is all a worker ever receives, delivered via
# Key Vault + managed identity (ADR 0004's Azure answer) so a compromised worker cannot
# rejoin as a control-plane/etcd member.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}

resource "random_string" "kv_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ---- Key Vault: RBAC authorization, agent token only ----
resource "azurerm_key_vault" "cluster" {
  name                      = local.kv_name
  resource_group_name       = var.resource_group_name
  location                  = var.location
  tenant_id                 = data.azurerm_client_config.current.tenant_id
  sku_name                  = "standard"
  enable_rbac_authorization = true
  tags                      = local.common_tags
}

# RBAC authorization grants nothing implicitly — the executing principal needs an explicit
# role to write the secret below. NOTE: Azure role assignments are eventually consistent
# (documented propagation delay of up to a few minutes); a first `tofu apply` immediately
# after vault creation may need to be re-run if the secret write races this assignment. See
# README for the operator-facing version of this note.
resource "azurerm_role_assignment" "kv_admin_self" {
  scope                = azurerm_key_vault.cluster.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "agent_token" {
  name         = "agent-token"
  value        = random_password.agent_token.result
  key_vault_id = azurerm_key_vault.cluster.id
  tags         = local.common_tags

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

# ---- STUB: replaced by the full internal Standard LB in Task 5 ----
resource "azurerm_lb" "control_plane" {
  count               = var.control_plane_count > 1 ? 1 : 0
  name                = "lb-${var.cluster_name}-cp"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tags                = local.common_tags

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.control_plane.id
    private_ip_address_allocation = "Dynamic"
  }
}
