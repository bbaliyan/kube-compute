# SPDX-License-Identifier: Apache-2.0
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
    defaults = {
      id                 = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkInterfaces/nic-bharat-cp-0"
      private_ip_address = "10.0.1.10"
    }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachines/vm-bharat-cp-0" }
  }
}

run "cluster_firewall_uses_asg_membership_not_cidr" {
  command = plan
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.2+rke2r1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D4s_v3"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-compute-test"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
  }
  assert {
    condition     = azurerm_network_security_rule.deny_ssh.access == "Deny"
    error_message = "deny_ssh rule must have access = Deny"
  }
  assert {
    condition     = azurerm_network_security_rule.deny_ssh.priority == 100
    error_message = "deny_ssh must be priority 100, the highest precedence"
  }
  assert {
    condition     = tolist(azurerm_network_security_rule.cluster_self.source_application_security_group_ids)[0] == azurerm_application_security_group.cluster.id
    error_message = "the cluster-wide rule must reference the cluster ASG as both source and destination"
  }
  assert {
    condition     = tolist(azurerm_network_security_rule.cluster_self.destination_application_security_group_ids)[0] == azurerm_application_security_group.cluster.id
    error_message = "the cluster-wide rule must reference the cluster ASG as both source and destination"
  }
  assert {
    condition     = azurerm_network_security_rule.etcd_peer.destination_port_range == "2379-2380"
    error_message = "the etcd rule must cover ports 2379-2380"
  }
  assert {
    condition     = tolist(azurerm_network_security_rule.etcd_peer.source_application_security_group_ids)[0] == azurerm_application_security_group.etcd.id
    error_message = "the etcd rule must scope to the etcd ASG, not the cluster-wide ASG"
  }
  assert {
    condition = !contains(
      [for r in azurerm_network_security_rule.allow_inbound : r.destination_port_range],
      "22"
    )
    error_message = "port 22 must not appear in any allow_inbound rule"
  }
}
