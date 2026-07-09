# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../cloud-init/templates/cloud-init-ubuntu-2604.yaml.tpl")

  # Azure-native delivery: raw IMDS + Key Vault REST calls, no az CLI dependency (see
  # spine-azure's design note 6 — Ubuntu 26.04 is not guaranteed to ship the Azure CLI, but
  # curl + python3 are always present). cloud-init only ever sees an opaque command it
  # executes at boot, never the Key Vault API itself.
  agent_token_fetch_command = "TOKEN=$(curl -s -H Metadata:true \"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net\" | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"access_token\"])') && curl -s -H \"Authorization: Bearer $TOKEN\" \"https://${var.key_vault_name}.vault.azure.net/secrets/${var.agent_token_secret_name}?api-version=7.4\" | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"value\"])'"

  node_labels = merge({ "topology.kubernetes.io/zone" = var.zone }, var.extra_node_labels)

  # Version-skew check: kubelet may trail the API server, never lead it.
  version_regex       = "^v(\\d+)\\.(\\d+)\\.(\\d+)\\+"
  pool_version_parts  = regex(local.version_regex, var.k8s_version)
  spine_version_parts = regex(local.version_regex, var.spine_k8s_version)
  pool_version_num    = tonumber(local.pool_version_parts[0]) * 1000000 + tonumber(local.pool_version_parts[1]) * 1000 + tonumber(local.pool_version_parts[2])
  spine_version_num   = tonumber(local.spine_version_parts[0]) * 1000000 + tonumber(local.spine_version_parts[1]) * 1000 + tonumber(local.spine_version_parts[2])

  image_parts     = var.os_image_urn != null ? split(":", var.os_image_urn) : []
  image_publisher = var.os_image_urn != null ? local.image_parts[0] : "Canonical"
  image_offer     = var.os_image_urn != null ? local.image_parts[1] : "ubuntu-26_04-lts"
  image_sku       = var.os_image_urn != null ? local.image_parts[2] : "server-gen2"
  image_version   = var.os_image_urn != null ? local.image_parts[3] : "latest"

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })
}

# ---- Node-scoped NSG — the pool owns only this; the spine's cluster ASG membership
# alone (below, on the VMSS network_interface) is not equivalent to attaching a security
# group: on Azure, an ASG is purely a label that NSG rules reference, and a NIC with no
# NSG attached falls back to the platform default rules (AllowVnetInBound), which permit
# all intra-VNet traffic including SSH. Mirrors spine-azure's control_plane NSG shape.
resource "azurerm_network_security_group" "worker" {
  name                = "nsg-${var.cluster_name}-worker"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

# SSH is always denied, at the highest priority (lowest number) — same rule shape as
# spine-azure's deny_ssh. Out-of-band access is via `az vm run-command invoke`.
resource "azurerm_network_security_rule" "deny_ssh" {
  name                        = "deny-ssh"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.worker.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

# East-west, cluster-wide: any protocol/port among members of the spine's cluster ASG —
# this pool's worker NICs are already members of that ASG (via application_security_group_ids
# below), so this rule lets them receive traffic from any other cluster member (control-plane
# or worker). Priority 110, same as spine-azure's cluster_self rule.
resource "azurerm_network_security_rule" "cluster_self" {
  name                                       = "allow-cluster-self"
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.worker.name
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "*"
  source_port_range                          = "*"
  destination_port_range                     = "*"
  source_application_security_group_ids      = [var.cluster_asg_id]
  destination_application_security_group_ids = [var.cluster_asg_id]
}

module "bootstrap" {
  source = "../cloud-init"

  # node_name deliberately omitted: this one cloud-init payload is shared by
  # every instance the VMSS creates (Terraform never sees individual
  # instances), so there's no static per-instance name to assign here. Leaving
  # it null lets cloud-init's Azure datasource assign its own naturally-unique
  # per-instance hostname instead of every instance colliding on the same one.
  cloud_init_template       = local.cloud_init_template
  cluster_name              = var.cluster_name
  k8s_version               = var.k8s_version
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  extra_tags                = var.extra_tags
}

# ---- Fixed worker pool: VM Scale Set, one zone, system-assigned managed identity ----
resource "azurerm_linux_virtual_machine_scale_set" "worker" {
  name                            = "vmss-${var.cluster_name}-worker"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  sku                             = var.vm_size
  instances                       = var.desired_count
  admin_username                  = var.admin_username
  disable_password_authentication = true
  upgrade_mode                    = "Manual"
  zones                           = [var.zone]
  single_placement_group          = false
  custom_data                     = module.bootstrap.user_data_base64
  tags                            = merge(local.common_tags, { Role = "worker" })

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = local.image_publisher
    offer     = local.image_offer
    sku       = local.image_sku
    version   = local.image_version
  }

  identity {
    type = "SystemAssigned"
  }

  network_interface {
    name                      = "nic-worker"
    primary                   = true
    network_security_group_id = azurerm_network_security_group.worker.id

    ip_configuration {
      name                           = "internal"
      primary                        = true
      subnet_id                      = data.azurerm_subnet.worker.id
      application_security_group_ids = [var.cluster_asg_id]
    }
  }

  lifecycle {
    precondition {
      condition     = local.pool_version_num <= local.spine_version_num
      error_message = "k8s_version (${var.k8s_version}) must not be newer than the spine's k8s_version (${var.spine_k8s_version})."
    }
  }
}

# ---- Least-privilege token read: scoped to this one secret, not the whole vault ----
resource "azurerm_role_assignment" "agent_token_read" {
  scope                = "${var.key_vault_id}/secrets/${var.agent_token_secret_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine_scale_set.worker.identity[0].principal_id
}
