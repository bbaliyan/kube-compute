# SPDX-License-Identifier: Apache-2.0
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = { tenant_id = "00000000-0000-0000-0000-000000000001", object_id = "00000000-0000-0000-0000-000000000002" }
  }
  mock_data "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s" }
  }
  mock_resource "azurerm_application_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/applicationSecurityGroups/asg-bharat-etcd" }
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

variables {
  cluster_name             = "bharat"
  k8s_version              = "v1.36.2+rke2r1"
  resource_group_name      = "rg-k8s"
  location                 = "eastus"
  vnet_name                = "vnet-main"
  subnet_name              = "snet-k8s"
  vm_size                  = "Standard_D4s_v3"
  admin_ssh_public_key     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-compute-test"
  allowed_ingress_cidrs    = ["10.0.0.0/8"]
  cluster_token            = "mock-server-token"
  cluster_agent_token      = "mock-agent-token"
  key_vault_id             = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.KeyVault/vaults/kvbharat123456"
  agent_token_secret_name  = "agent-token"
  cluster_asg_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/applicationSecurityGroups/asg-bharat-cluster"
}

run "no_domain_means_no_dns_record" {
  command = apply
  assert {
    condition     = length(azurerm_dns_a_record.wildcard) == 0
    error_message = "no cluster_domain means no DNS record should be created"
  }
  assert {
    condition     = output.wildcard_dns_name == null
    error_message = "no cluster_domain means wildcard_dns_name output must be null"
  }
}

run "domain_and_zone_creates_wildcard_record" {
  command = apply
  variables {
    cluster_domain          = "example.com"
    dns_zone_resource_group = "rg-dns"
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
