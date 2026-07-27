# azure-control-plane

Control plane for a kube-compute cluster on Azure: discrete `azurerm_linux_virtual_machine`
control-plane pets (1, 3, or 5 — one per availability zone), an internal Standard Load Balancer
registration endpoint for HA, an Application Security Group + NSG cluster firewall, and join
tokens delivered via Key Vault (RBAC authorization).

## What this module creates

- One `azurerm_linux_virtual_machine` per control-plane node, each with its own NIC.
- `control_plane_count > 1`: an internal Standard `azurerm_lb` on port 6443, backing every
  control-plane NIC. `registration_address` is this LB's frontend private IP.
- Two Application Security Groups: `cluster` (all members, all ports/protocols) and `etcd`
  (control-plane-only, ports 2379-2380) — the Azure equivalent of AWS's self-referencing
  security group. `azure-node-pool` joins the `cluster` ASG by id; it never creates one.
- One Key Vault (`rbac_authorization_enabled = true`) holding the agent join token as a secret.
  The server token is delivered directly to each control-plane node as a run-command protected
  parameter — control-plane nodes never read from Key Vault.
- One `azurerm_virtual_machine_run_command` per node that delivers the `node-bootstrap` `on_node`
  bundle. Bootstrap runs on the node itself (Ansible `-c local`); secrets ride as protected
  parameters (injected as environment variables), so nothing sensitive lands in `custom_data` or
  state, and **no inbound port is opened** — the `deny-ssh` NSG rule (priority 100) stays. This is
  the same `az vm run-command` primitive the control-plane verb-scripts use.

## What this module never creates

VNets, subnets, or any other network fabric — pass an existing `vnet_name`/`subnet_name`.
Azure has no default VNet (unlike AWS), so both are always required.

## Known limitations

- **Key Vault RBAC propagation delay.** Azure role assignments are eventually consistent
  (documented delay of up to a few minutes). If `tofu apply` fails writing the
  `agent-token` secret on a brand-new vault, re-run `tofu apply` — the role assignment
  will have propagated by then. This module does not add a blocking sleep for this.
- **No `dns`/`static` endpoint_mode.** Unlike `aws-control-plane`, this module supports only the
  internal-LB registration endpoint — `dns`/`static` alternatives are out of scope and
  can be added later behind the same `endpoint_mode` variable name aws-control-plane already uses.
- **Single-region placement only.** All control-plane VMs land in `location`, spread across
  `availability_zones` — cross-region spread is out of scope (matches proxmox-control-plane's
  single-Proxmox-node limitation note).
- **No working example provided.** Azure validation is manual-tier — this repo has no
  live Azure subscription to test `init`/`plan`/`apply` against. `examples/basic/main.tf`
  is unverified beyond `tofu validate`.
