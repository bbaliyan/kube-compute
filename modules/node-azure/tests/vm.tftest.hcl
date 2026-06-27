# SPDX-License-Identifier: Apache-2.0
mock_provider "azurerm" {
  mock_data "azurerm_subnet" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s"
    }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/kube-node-bharat" }
  }
  mock_resource "azurerm_network_security_rule" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/kube-node-bharat/securityRules/deny-ssh" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkInterfaces/kube-node-bharat"
      private_ip_address = "10.0.1.10"
    }
  }
  mock_resource "azurerm_network_interface_security_group_association" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkInterfaces/kube-node-bharat|/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/kube-node-bharat" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachines/kube-node-bharat"
      private_ip_address = "10.0.1.10"
    }
  }
}

run "static_ip_default_image" {
  command = plan
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D4s_v3"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs = ["10.0.0.0/8", "192.168.0.0/16"]
    vm_private_ip         = "10.0.1.10"
  }
  assert {
    condition     = output.cluster_ip == "10.0.1.10"
    error_message = "static vm_private_ip must be the cluster_ip"
  }
  assert {
    condition     = output.node_provider == "azure"
    error_message = "node_provider must be the literal string 'azure'"
  }
  assert {
    condition     = output.node_arch == "x86_64"
    error_message = "node_arch default must be x86_64"
  }
  assert {
    condition     = output.cluster_fqdn == null
    error_message = "no cluster_domain means cluster_fqdn must be null"
  }
  assert {
    condition     = output.wildcard_dns_name == null
    error_message = "no cluster_domain means wildcard_dns_name must be null"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.node.disable_password_authentication == true
    error_message = "password authentication must be disabled"
  }
  assert {
    condition     = length(azurerm_linux_virtual_machine.node.custom_data) > 0
    error_message = "VM must have cloud-init custom_data from node-bootstrap"
  }
  assert {
    condition     = azurerm_network_security_rule.deny_ssh.access == "Deny"
    error_message = "deny_ssh rule must have access = Deny"
  }
  assert {
    condition     = azurerm_network_security_rule.deny_ssh.destination_port_range == "22"
    error_message = "deny_ssh rule must target port 22"
  }
  assert {
    condition     = azurerm_network_security_rule.deny_ssh.priority == 100
    error_message = "deny_ssh must be priority 100 (lowest valid Azure priority = highest precedence, processed before allow rules at 200+)"
  }
  assert {
    condition = !contains(
      [for r in azurerm_network_security_rule.allow_inbound : r.destination_port_range],
      "22"
    )
    error_message = "port 22 must not appear in any allow_inbound rule"
  }
  assert {
    condition = contains(
      [for r in azurerm_network_security_rule.allow_inbound : r.destination_port_range],
      "6443"
    )
    error_message = "K3s API port 6443 must be in allow_inbound rules"
  }
}

run "arm64_explicit" {
  command = plan
  variables {
    cluster_name          = "arm-lab"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D4ps_v5"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    node_arch             = "arm64"
    os_image_urn          = "Canonical:ubuntu-26_04-lts:server-gen2:latest"
    vm_private_ip         = "10.0.1.20"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "explicit node_arch = arm64 must pass through to the output"
  }
}

run "dhcp_custom_image" {
  command = plan
  # vm_private_ip omitted → dynamic allocation; cluster_ip comes from mock NIC.
  variables {
    cluster_name          = "dhcp-test"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "westeurope"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D2s_v3"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    os_image_urn          = "Canonical:ubuntu-26_04-lts:server-gen2:latest"
  }
  assert {
    condition     = output.cluster_ip == "10.0.1.10"
    error_message = "DHCP cluster_ip must come from mock NIC private_ip_address"
  }
}
