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

run "single_node_no_endpoint" {
  command = apply
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
    condition     = azurerm_linux_virtual_machine.control_plane.disable_password_authentication == true
    error_message = "password authentication must be disabled"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.control_plane.custom_data == null
    error_message = "genesis VM must carry no custom_data — bootstrap is delivered via run-command, not cloud-init"
  }
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.genesis.source[0].script, "ansible-playbook")
    error_message = "genesis run-command must deliver the node-bootstrap on_node bundle"
  }
  assert {
    condition     = length(azurerm_network_interface.control_plane) == 1
    error_message = "control_plane_count = 1 must create exactly one NIC"
  }
}
