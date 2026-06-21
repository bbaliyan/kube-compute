# SPDX-License-Identifier: Apache-2.0
mock_provider "azurerm" {
  mock_data "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s"
    }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/kube-node-dns-test" }
  }
  mock_resource "azurerm_network_security_rule" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/kube-node-dns-test/securityRules/deny-ssh" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkInterfaces/kube-node-dns-test"
      private_ip_address = "10.0.1.5"
    }
  }
  mock_resource "azurerm_network_interface_security_group_association" {
    defaults = { id = "association-dns-test" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachines/kube-node-dns-test"
      private_ip_address = "10.0.1.5"
    }
  }
  mock_resource "azurerm_dns_a_record" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-dns/providers/Microsoft.Network/dnszones/example.com/A/*.dns-test" }
  }
}

run "cluster_domain_produces_names" {
  command = plan
  variables {
    cluster_name            = "dns-test"
    k8s_version             = "v1.36.1+k3s1"
    resource_group_name     = "rg-k8s"
    location                = "eastus"
    vnet_name               = "vnet-main"
    subnet_name             = "snet-k8s"
    vm_size                 = "Standard_D4s_v3"
    admin_ssh_public_key    = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs   = ["10.0.0.0/8"]
    vm_private_ip           = "10.0.1.5"
    cluster_domain          = "example.com"
    dns_zone_resource_group = "rg-dns"
  }
  assert {
    condition     = output.cluster_fqdn == "api.dns-test.example.com"
    error_message = "cluster_fqdn must be api.<cluster_name>.<cluster_domain>"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.dns-test.example.com"
    error_message = "wildcard_dns_name must be *.<cluster_name>.<cluster_domain>"
  }
  assert {
    condition     = length(azurerm_dns_a_record.wildcard) == 1
    error_message = "providing both cluster_domain and dns_zone_resource_group must create the DNS record"
  }
  assert {
    condition     = azurerm_dns_a_record.wildcard[0].name == "*.dns-test"
    error_message = "DNS record name must be *.<cluster_name> (relative to the zone)"
  }
}

run "no_domain_is_ip_only" {
  command = plan
  variables {
    cluster_name          = "dns-test"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D4s_v3"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    vm_private_ip         = "10.0.1.5"
    # cluster_domain omitted — IP-only mode
  }
  assert {
    condition     = output.cluster_fqdn == null
    error_message = "no cluster_domain must yield null cluster_fqdn"
  }
  assert {
    condition     = output.wildcard_dns_name == null
    error_message = "no cluster_domain must yield null wildcard_dns_name"
  }
  assert {
    condition     = length(azurerm_dns_a_record.wildcard) == 0
    error_message = "no cluster_domain must produce zero DNS records"
  }
}

run "domain_without_zone_rg_skips_record" {
  command = plan
  # cluster_domain set but dns_zone_resource_group omitted → names produced, no record.
  variables {
    cluster_name          = "dns-test"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D4s_v3"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    vm_private_ip         = "10.0.1.5"
    cluster_domain        = "example.com"
    # dns_zone_resource_group omitted — self-service DNS, no auto-record
  }
  assert {
    condition     = output.cluster_fqdn == "api.dns-test.example.com"
    error_message = "cluster_fqdn must still be set even without dns_zone_resource_group"
  }
  assert {
    condition     = output.wildcard_dns_name == "*.dns-test.example.com"
    error_message = "wildcard_dns_name must still be set even without dns_zone_resource_group"
  }
  assert {
    condition     = length(azurerm_dns_a_record.wildcard) == 0
    error_message = "no dns_zone_resource_group must produce zero DNS records"
  }
}
