# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  # Azure-native delivery: raw IMDS + Key Vault REST calls, no az CLI dependency (see
  # azure-control-plane's design note 6 — AlmaLinux 10 is not guaranteed to ship the Azure CLI, but
  # curl + python3 are always present). node-bootstrap only ever runs this as an opaque command on
  # the node at join time, never the Key Vault API itself.
  agent_token_fetch_command = "TOKEN=$(curl -s -H Metadata:true \"http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net\" | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"access_token\"])') && curl -s -H \"Authorization: Bearer $TOKEN\" \"https://${var.key_vault_name}.vault.azure.net/secrets/${var.agent_token_secret_name}?api-version=7.4\" | python3 -c 'import sys,json;print(json.load(sys.stdin)[\"value\"])'"

  node_labels = merge({ "topology.kubernetes.io/zone" = var.zone }, var.extra_node_labels)

  # Falls back to the platform-wide default when the caller doesn't override k8s_version.
  k8s_version = coalesce(var.k8s_version, module.component_versions.k8s_version)

  image_parts     = var.os_image_urn != null ? split(":", var.os_image_urn) : []
  image_publisher = var.os_image_urn != null ? local.image_parts[0] : "almalinux"
  image_offer     = var.os_image_urn != null ? local.image_parts[1] : "almalinux-x86_64"
  image_sku       = var.os_image_urn != null ? local.image_parts[2] : "10-gen2"
  image_version   = var.os_image_urn != null ? local.image_parts[3] : "latest"

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })

  # Fixed pool: one discrete VM per index (like proxmox-node-pool), so each worker
  # gets a stable node_name — unlike the old VMSS, where Terraform never saw
  # individual instances and had to leave the name to the Azure datasource.
  worker_indices = { for i in range(var.desired_count) : tostring(i) => i }
}

# ---- Node-scoped NSG — the pool owns only this. A NIC with no NSG falls back to
# the platform default rules (AllowVnetInBound), which permit all intra-VNet traffic
# including SSH. Mirrors azure-control-plane's control_plane NSG shape.
resource "azurerm_network_security_group" "worker" {
  name                = "nsg-${var.cluster_name}-worker"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

# SSH is always denied, at the highest priority — same rule shape as azure-control-plane's
# deny_ssh. Out-of-band access is via `az vm run-command`, which is also how these workers
# are bootstrapped — no inbound port.
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

# East-west, cluster-wide: any protocol/port among members of the control plane's cluster ASG —
# this pool's worker NICs are members of that ASG (association below). Priority 110, same as
# azure-control-plane's cluster_self rule.
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

# ---- Per-worker NIC, NSG + cluster-ASG membership ----
resource "azurerm_network_interface" "worker" {
  for_each = local.worker_indices

  name                = "nic-${var.cluster_name}-worker-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.worker.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "worker" {
  for_each = azurerm_network_interface.worker

  network_interface_id      = each.value.id
  network_security_group_id = azurerm_network_security_group.worker.id
}

resource "azurerm_network_interface_application_security_group_association" "cluster" {
  for_each = azurerm_network_interface.worker

  network_interface_id          = each.value.id
  application_security_group_id = var.cluster_asg_id
}

# ---- node-bootstrap on_node bundle, one per worker (worker role) ----
module "bootstrap" {
  for_each = local.worker_indices

  source = "../node-bootstrap"

  invocation_mode           = "on_node"
  ansible_playbook_path     = var.ansible_playbook_path
  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-worker-${each.key}"
  k8s_version               = local.k8s_version
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
}

# ---- Fixed pool: discrete VMs, one per index, all in the pool's zone ----
resource "azurerm_linux_virtual_machine" "worker" {
  for_each = local.worker_indices

  name                            = "vm-${var.cluster_name}-worker-${each.key}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.worker[each.key].id]
  zone                            = var.zone
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

  # System-assigned identity so this worker can read its agent token from Key Vault
  # (role assignment below). No custom_data — bootstrap is delivered via run-command.
  identity {
    type = "SystemAssigned"
  }
}

# ---- Least-privilege token read: each worker's identity, scoped to this one secret ----
resource "azurerm_role_assignment" "agent_token_read" {
  for_each = local.worker_indices

  scope                = "${var.key_vault_id}/secrets/${var.agent_token_secret_name}"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.worker[each.key].identity[0].principal_id
}

# ---- Bootstrap delivery: az vm run-command, one per worker ----
# The portless Azure transport (constraint 6): run-command pushes node-bootstrap's
# on_node bundle and Ansible runs on the node. The agent token is fetched on-node
# from Key Vault via the VM's managed identity, so this depends_on the role
# assignment — the identity must be able to read the secret before the bundle runs.
# See azure-control-plane for the protected-parameter/env-var and AlmaLinux-10
# run-command assumptions still pending real-apply verification.
resource "azurerm_virtual_machine_run_command" "worker" {
  for_each = local.worker_indices

  name               = "kube-compute-bootstrap"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.worker[each.key].id

  source {
    script = module.bootstrap[each.key].on_node_bundle
  }

  dynamic "protected_parameter" {
    for_each = nonsensitive(toset(keys(module.bootstrap[each.key].on_node_secret_env)))
    content {
      name  = protected_parameter.value
      value = module.bootstrap[each.key].on_node_secret_env[protected_parameter.value]
    }
  }

  depends_on = [azurerm_role_assignment.agent_token_read]
}
