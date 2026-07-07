# SPDX-License-Identifier: Apache-2.0
# Read-only Azure lookups. No fabric-creating resource belongs in this file, ever.

data "azurerm_client_config" "current" {}

data "azurerm_subnet" "control_plane" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = coalesce(var.network_resource_group_name, var.resource_group_name)
}
