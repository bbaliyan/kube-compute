# azure-node-pool

**Placeholder — not implemented.** Azure is one of this project's three target
providers (AWS, Proxmox, Azure), but there is currently no working
`azure-node-pool` module. This directory intentionally contains no `.tf`
files.

## Why

An earlier implementation existed here: a fixed, AZ-pinned Azure node pool
(discrete VMs) joining an existing `azure-control-plane` cluster, using live
Ansible pushed at apply time via `azurerm_virtual_machine_run_command`. It was
removed alongside `modules/azure-control-plane` because it was never validated
against real Azure infrastructure — the development environment this project
is built in has no Azure connectivity, so nothing in that implementation
(including its `tofu test` mocks) was ever exercised against an actual
subscription. Carrying an unvalidated implementation forward as if it were
trustworthy was judged worse than removing it and starting clean.

## Intended future direction

When Azure support is revisited, the plan is to follow the same pattern
`aws-node-pool`/`proxmox-node-pool` now use rather than reintroduce live
Ansible:

- Boot from a pre-baked `kube-image` template (RKE2 binaries, prerequisites,
  and the Cilium manifest already on disk) instead of installing at boot.
- Attach a lean `#cloud-config` payload rendered by `modules/node-bootstrap`
  (its current, post-cutover interface) to configure and join RKE2 —
  no execution engine, no inbound connection to the node.
- Fetch the agent join token from Azure Key Vault via Managed Identity, the
  Azure-native equivalent of AWS's SSM `SecureString` fetch, instead of
  `azurerm_virtual_machine_run_command`'s protected parameters.

This module also depended on `modules/azure-cluster-facts` (now deleted, since
its only consumers were `azure-control-plane`/`azure-node-pool`) for the
cluster's Key Vault, Application Security Group, and join tokens. Any future
Azure implementation should re-evaluate whether that split is still the right
shape once the kube-image/lean-cloud-init pattern is in use.

This work should not start until AWS and Proxmox are fully proven (validated
against real infrastructure, not just `tofu test` mocks).
