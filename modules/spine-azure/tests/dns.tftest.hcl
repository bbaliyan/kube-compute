# SPDX-License-Identifier: Apache-2.0
# random_string/random_password are real (unmocked) resources whose computed
# attributes are genuinely unknown at plan time for a not-yet-created resource.
# local.kv_name derives from random_string.kv_suffix.result, and the
# key_vault_name assertion below needs that value known at plan time, so the
# random provider is mocked too (same pattern as tests/tokens.tftest.hcl).
# Note: `name` on azurerm_key_vault is a non-computed config-derived field —
# OpenTofu's test mocking rejects overriding it directly (the brief's literal
# test content tried to do so), so instead we pin random_string's result to
# "123456" and let local.kv_name ("kv" + "bharat" + "123456") compute to the
# same "kvbharat123456" the brief expects.
mock_provider "random" {
  mock_resource "random_string" {
    defaults = { result = "123456" }
  }
}

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "00000000-0000-0000-0000-000000000001", object_id = "00000000-0000-0000-0000-000000000002" }
  }
  mock_data "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s" }
  }
  mock_resource "azurerm_key_vault" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.KeyVault/vaults/kvbharat123456" }
  }
  mock_resource "azurerm_application_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/applicationSecurityGroups/asg-bharat-cluster" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/nsg-bharat-cp" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkInterfaces/nic-bharat-cp-0", private_ip_address = "10.0.1.10" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachines/vm-bharat-cp-0" }
  }
  mock_resource "azurerm_dns_a_record" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/dnszones/example.com/A/*.bharat" }
  }
}

run "no_domain_means_no_dns_record" {
  command = apply
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location               = "eastus"
    vnet_name               = "vnet-main"
    subnet_name             = "snet-k8s"
    vm_size                 = "Standard_D4s_v3"
    admin_ssh_public_key    = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs   = ["10.0.0.0/8"]
  }
  assert {
    condition     = length(azurerm_dns_a_record.wildcard) == 0
    error_message = "no cluster_domain means no DNS record should be created"
  }
  assert {
    condition     = output.wildcard_dns_name == null
    error_message = "no cluster_domain means wildcard_dns_name output must be null"
  }
  assert {
    condition     = output.key_vault_name == "kvbharat123456"
    error_message = "key_vault_name output must surface the vault's actual name"
  }
  assert {
    condition     = output.agent_token_secret_name == "agent-token"
    error_message = "agent_token_secret_name output must be 'agent-token'"
  }
}

run "domain_and_zone_creates_wildcard_record" {
  command = apply
  variables {
    cluster_name             = "bharat"
    k8s_version              = "v1.36.1+k3s1"
    resource_group_name      = "rg-k8s"
    location                  = "eastus"
    vnet_name                  = "vnet-main"
    subnet_name                = "snet-k8s"
    vm_size                     = "Standard_D4s_v3"
    admin_ssh_public_key        = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs        = ["10.0.0.0/8"]
    cluster_domain                = "example.com"
    dns_zone_resource_group        = "rg-dns"
  }
  assert {
    condition     = length(azurerm_dns_a_record.wildcard) == 1
    error_message = "cluster_domain + dns_zone_resource_group must create exactly one wildcard A record"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.bharat.example.com"
    error_message = "wildcard_dns_name must be *.<cluster_name>.<cluster_domain>"
  }
  assert {
    condition     = output.cluster_fqdn == "api.bharat.example.com"
    error_message = "cluster_fqdn must be api.<cluster_name>.<cluster_domain>"
  }
}
