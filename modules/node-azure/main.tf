# SPDX-License-Identifier: Apache-2.0

locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../node-bootstrap/templates/cloud-init-ubuntu-2604.yaml.tpl")

  # DNS naming — optional. Creates an Azure DNS wildcard A record only when both
  # cluster_domain and dns_zone_resource_group are provided.
  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  create_record = local.has_domain && var.dns_zone_resource_group != null

  # VNet may live in a different RG (hub-spoke). Default to the VM's RG.
  network_rg = coalesce(var.network_resource_group_name, var.resource_group_name)

  # OS image: split a user-provided URN (Publisher:Offer:SKU:Version) or default to
  # Ubuntu 26.04 LTS gen2. The user must supply an arm64 SKU when node_arch = "arm64".
  # Note: the default offer name follows Canonical's LTS convention; verify it is
  # available in the target region with:
  #   az vm image list --publisher Canonical --offer ubuntu-26 --all --output table
  image_parts     = var.os_image_urn != null ? split(":", var.os_image_urn) : []
  image_publisher = var.os_image_urn != null ? local.image_parts[0] : "Canonical"
  image_offer     = var.os_image_urn != null ? local.image_parts[1] : "ubuntu-26_04-lts"
  image_sku       = var.os_image_urn != null ? local.image_parts[2] : "server-gen2"
  image_version   = var.os_image_urn != null ? local.image_parts[3] : "latest"

  common_tags = {
    cluster_name = var.cluster_name
    managed_by   = "kube-node"
  }
}

# Subnet data lookup — the module takes a network handle; never creates fabric.
data "azurerm_subnet" "node" {
  name                 = var.subnet_name
  virtual_network_name = var.vnet_name
  resource_group_name  = local.network_rg
}

module "bootstrap" {
  source = "../node-bootstrap"

  cloud_init_template       = local.cloud_init_template
  cluster_name              = var.cluster_name
  k8s_version               = var.k8s_version
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  gitops_platform_repo_url  = var.gitops_platform_repo_url
  gitops_platform_revision  = var.gitops_platform_revision
  gitops_workloads_repo_url = var.gitops_workloads_repo_url
  gitops_workloads_revision = var.gitops_workloads_revision
  gitops_workloads_path     = var.gitops_workloads_path
  cluster_fqdn              = local.cluster_fqdn
}

# ---- Node-scoped NSG — the module owns only this; VNet/subnet are never touched ----
resource "azurerm_network_security_group" "node" {
  name                = "kube-node-${var.cluster_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags
}

# SSH is always denied, at the highest priority (lowest number), regardless of ingress_ports.
# Azure NSG priority range is 100–4096; lower number = higher priority.
# Out-of-band access is via `az vm run-command invoke` — no inbound port required.
resource "azurerm_network_security_rule" "deny_ssh" {
  name                        = "deny-ssh"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.node.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
}

# One allow rule per port, accepting traffic from all allowed_ingress_cidrs.
# Priorities: 200, 210, 220 ... — above the deny-ssh at 100 (higher number = lower priority)
# so deny wins if port 22 were ever added to ingress_ports (the variable validates against it).
resource "azurerm_network_security_rule" "allow_inbound" {
  for_each = {
    for idx, port in var.ingress_ports :
    tostring(port) => { port = port, priority = 200 + idx * 10 }
  }

  name                        = "allow-${each.key}"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.node.name
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.port)
  source_address_prefixes     = var.allowed_ingress_cidrs
  destination_address_prefix  = "*"
}

# ---- NIC + NSG association ----
resource "azurerm_network_interface" "node" {
  name                = "kube-node-${var.cluster_name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.node.id
    private_ip_address_allocation = var.vm_private_ip != null ? "Static" : "Dynamic"
    private_ip_address            = var.vm_private_ip
  }
}

resource "azurerm_network_interface_security_group_association" "node" {
  network_interface_id      = azurerm_network_interface.node.id
  network_security_group_id = azurerm_network_security_group.node.id
}

# ---- The Azure Linux VM ----
resource "azurerm_linux_virtual_machine" "node" {
  name                            = "kube-node-${var.cluster_name}"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.node.id]
  tags                            = local.common_tags

  # Azure requires an SSH key for password-auth-disabled Linux VMs.
  # Port 22 is denied by the NSG — this key can never be used to log in remotely.
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

  # Cloud-init user-data from node-bootstrap (base64gzip). Azure decodes and runs
  # this on first boot via the Azure Linux Agent / cloud-init integration.
  custom_data = module.bootstrap.user_data_base64
}

# ---- Optional: wildcard A record in an Azure DNS zone you already own ----
# Created only when both cluster_domain and dns_zone_resource_group are set.
# Otherwise register *.<cluster_name>.<cluster_domain> → cluster_ip yourself.
resource "azurerm_dns_a_record" "wildcard" {
  count               = local.create_record ? 1 : 0
  name                = "*.${var.cluster_name}"
  resource_group_name = var.dns_zone_resource_group
  zone_name           = var.cluster_domain
  ttl                 = 60
  records             = [var.vm_private_ip != null ? var.vm_private_ip : azurerm_network_interface.node.private_ip_address]
  tags                = local.common_tags
}
