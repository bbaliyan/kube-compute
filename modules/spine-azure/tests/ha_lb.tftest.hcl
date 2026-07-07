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
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkInterfaces/nic-bharat-cp" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachines/vm-bharat-cp" }
  }
  mock_resource "azurerm_lb" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/loadBalancers/lb-bharat-cp" }
  }
  mock_resource "azurerm_lb_backend_address_pool" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/loadBalancers/lb-bharat-cp/backendAddressPools/cp-backend" }
  }
  mock_resource "azurerm_lb_probe" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/loadBalancers/lb-bharat-cp/probes/cp-probe" }
  }
}

run "single_node_creates_no_lb" {
  command = apply
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D4s_v3"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
  }
  assert {
    condition     = length(azurerm_lb.control_plane) == 0
    error_message = "control_plane_count = 1 must create no load balancer (ADR 0003 — no registration endpoint at all)"
  }
  assert {
    condition     = output.registration_address == null
    error_message = "control_plane_count = 1 must expose a null registration_address"
  }
}

run "ha_creates_lb_and_two_additional_vms" {
  command = apply
  # Only computed fields can be overridden — name and private_ip_address_allocation
  # are non-computed (set explicitly in main.tf's frontend_ip_configuration block),
  # and OpenTofu rejects overriding non-computed fields. `id` is re-specified here
  # too: override_resource replaces the whole mock_resource-derived value set for
  # this resource, so without it OpenTofu synthesizes a random id instead of
  # reusing the mock_resource "azurerm_lb" default declared above, which breaks the
  # downstream azurerm_lb_backend_address_pool/probe/rule resources that parse
  # loadbalancer_id as a real Azure resource ID. This override exists purely to give
  # the test a deterministic frontend private_ip_address to assert on; it changes
  # nothing about main.tf itself.
  override_resource {
    target = azurerm_lb.control_plane
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/loadBalancers/lb-bharat-cp"
      frontend_ip_configuration = {
        private_ip_address = "10.0.1.100"
      }
    }
  }
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.36.1+k3s1"
    resource_group_name   = "rg-k8s"
    location              = "eastus"
    vnet_name             = "vnet-main"
    subnet_name           = "snet-k8s"
    vm_size               = "Standard_D4s_v3"
    admin_ssh_public_key  = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-node-test"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    control_plane_count   = 3
  }
  assert {
    condition     = length(azurerm_linux_virtual_machine.control_plane_additional) == 2
    error_message = "control_plane_count = 3 must create exactly 2 additional control-plane VMs"
  }
  assert {
    condition     = azurerm_lb.control_plane[0].sku == "Standard"
    error_message = "the registration LB must be Standard SKU (required for internal LB + zone-aware backends)"
  }
  assert {
    condition     = output.registration_address == "10.0.1.100"
    error_message = "control_plane_count > 1 must use the LB's frontend private IP as registration_address"
  }
  assert {
    condition     = length(output.control_plane_node_refs) == 3
    error_message = "control_plane_node_refs must have one entry per control-plane node"
  }
}

run "invalid_control_plane_count_rejected" {
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
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    control_plane_count   = 2
  }
  expect_failures = [var.control_plane_count]
}
