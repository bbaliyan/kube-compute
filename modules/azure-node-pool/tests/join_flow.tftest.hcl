# SPDX-License-Identifier: Apache-2.0
mock_provider "azurerm" {
  mock_data "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-main/subnets/snet-k8s" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkSecurityGroups/nsg-bharat-worker" }
  }
  mock_resource "azurerm_linux_virtual_machine" {
    defaults = {
      id       = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Compute/virtualMachines/vm-bharat-worker-0"
      identity = { principal_id = "00000000-0000-0000-0000-000000000099", tenant_id = "00000000-0000-0000-0000-000000000001" }
    }
  }
  mock_resource "azurerm_role_assignment" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleAssignments/00000000-0000-0000-0000-000000000004" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/networkInterfaces/nic-bharat-worker-0" }
  }
}

run "workers_are_discrete_vms_joining_via_run_command_and_key_vault" {
  command = apply
  variables {
    cluster_name              = "bharat"
    k8s_version               = "v1.36.2+rke2r1"
    resource_group_name       = "rg-k8s"
    location                  = "eastus"
    vnet_name                 = "vnet-main"
    subnet_name               = "snet-k8s"
    vm_size                   = "Standard_D2s_v3"
    admin_ssh_public_key      = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDOF9Xy9WCQuyo/3og15+j5Ss+TmRR2ZvyK7fMy6jm707lpCAWUUSObF5ASCdyCmOkEN4+AffIB9evB4Jl+InhAglVSxYo+BTkUPraqzUU/CWTK/uecwCHsa497QCGmdUFaCQTt67WNFxFXJgvoDkKg0bWErs6W0zrEjj4z063GnN4Mj8bChd7GnQ+J8Lu6DryBtJRAIq4V7Nu7V4U91dhcffiX07k9OHLQDRReFCBGeXBK+HcQKFopoD1F5uVKlq8igF7U0HKTFup6IeE11+iRu7X2l6HbOda98Jgbu/PFue57yBdHgla9QFWvC0kyaw5V0DTJ6gG4Dpw35cLwiHct ci@kube-compute-test"
    zone                      = "1"
    desired_count             = 2
    registration_address      = "10.0.1.100"
    key_vault_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.KeyVault/vaults/kvbharat123456"
    key_vault_name            = "kvbharat123456"
    agent_token_secret_name   = "agent-token"
    cluster_asg_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-k8s/providers/Microsoft.Network/applicationSecurityGroups/asg-bharat-cluster"
  }
  # Discrete VMs, not a VMSS.
  assert {
    condition     = length(azurerm_linux_virtual_machine.worker) == 2
    error_message = "desired_count = 2 must create two discrete worker VMs"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.worker["0"].zone == "1"
    error_message = "every worker VM must be pinned to the single configured zone"
  }
  # Bootstrap delivered via run-command.
  assert {
    condition     = strcontains(azurerm_virtual_machine_run_command.worker["0"].source[0].script, "ansible-playbook")
    error_message = "each worker's run-command must deliver the node-bootstrap on_node bundle"
  }
  # The agent-token fetch is delivered out-of-band as a protected parameter, NOT
  # embedded in the bundle (the IMDS/Key-Vault call must not appear in the script).
  assert {
    condition     = contains([for p in azurerm_virtual_machine_run_command.worker["0"].protected_parameter : p.name], "AGENT_TOKEN_FETCH_COMMAND")
    error_message = "the agent-token fetch command must ride as a protected parameter"
  }
  assert {
    condition     = !strcontains(azurerm_virtual_machine_run_command.worker["0"].source[0].script, "169.254.169.254")
    error_message = "the token fetch (IMDS) must not be embedded in the bundle — it is a protected parameter"
  }
  assert {
    condition     = !strcontains(azurerm_virtual_machine_run_command.worker["0"].source[0].script, "aws ssm")
    error_message = "an Azure worker must never reference AWS SSM"
  }
  # Least-privilege token read, per worker identity, scoped to the one secret.
  assert {
    condition     = azurerm_role_assignment.agent_token_read["0"].role_definition_name == "Key Vault Secrets User"
    error_message = "the worker identity must be granted Key Vault Secrets User, not a broader role"
  }
  assert {
    condition     = azurerm_role_assignment.agent_token_read["0"].scope == "${var.key_vault_id}/secrets/${var.agent_token_secret_name}"
    error_message = "the role assignment must be scoped to the individual secret, not the whole vault"
  }
}
