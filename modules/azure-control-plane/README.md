# azure-control-plane

**Placeholder — not implemented.** Azure is one of this project's three target
providers (AWS, Proxmox, Azure), but there is currently no working
`azure-control-plane` module. This directory intentionally contains no `.tf`
files.

## Why

An earlier implementation existed here: Azure control-plane node(s) plus
cluster-wide resources (join tokens via Key Vault, cluster/etcd Application
Security Groups, an internal Standard Load Balancer registration endpoint),
using live Ansible pushed at apply time via
`azurerm_virtual_machine_run_command`. It was removed because it was never
validated against real Azure infrastructure — the development environment
this project is built in has no Azure connectivity, so nothing in that
implementation (including its `tofu test` mocks) was ever exercised against
an actual subscription. Carrying an unvalidated implementation forward as if
it were trustworthy was judged worse than removing it and starting clean.

## Intended future direction

When Azure support is revisited, the plan is to follow the same pattern
`aws-control-plane`/`proxmox-control-plane` now use rather than reintroduce
live Ansible:

- Boot from a pre-baked `kube-image` template (RKE2 binaries, prerequisites,
  and the Cilium manifest already on disk) instead of installing at boot.
- Attach a lean `#cloud-config` payload rendered by `modules/node-bootstrap`
  (its current, post-cutover interface) to configure and start RKE2 —
  no execution engine, no inbound connection to the node.
- Deliver the agent join token via Azure Key Vault + Managed Identity, the
  Azure-native equivalent of AWS's SSM `SecureString` approach, instead of
  `azurerm_virtual_machine_run_command`'s protected parameters.

This work should not start until AWS and Proxmox are fully proven (validated
against real infrastructure, not just `tofu test` mocks).
