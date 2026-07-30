# azure-control-plane

Control plane for a kube-compute cluster on Azure: discrete `azurerm_linux_virtual_machine`
control-plane pets (1, 3, or 5 — one per availability zone), an internal Standard Load Balancer
registration endpoint for HA, and an Application Security Group + NSG cluster firewall.

This module no longer generates the join tokens or the Key Vault that holds them. They come from
this cluster's `azure-cluster-facts` unit, which applies first and fast, so a node pool no longer
has to wait on the control plane's full apply for them: `cluster_token` (the **server token**, used
for both the genesis `server-init` and every additional `server-join` node) and
`cluster_agent_token` (the **agent token**, passed to the genesis node-bootstrap call only —
workers never receive it directly, they read it from `azure-cluster-facts`'s Key Vault via their
own managed-identity role assignment). Both are required, sensitive inputs here. `k8s_version` is
required for the same reason: both this module and `azure-node-pool` consume the one resolved
value from `azure-cluster-facts`, so version skew between them is prevented by construction.

## What this module creates

- One `azurerm_linux_virtual_machine` per control-plane node, each with its own NIC.
- `control_plane_count > 1`: an internal Standard `azurerm_lb` on port 6443, backing every
  control-plane NIC. `registration_address` is this LB's frontend private IP.
- The `etcd` Application Security Group (control-plane-only, ports 2379-2380). The cluster-wide
  ASG (all members, all ports/protocols — the Azure equivalent of AWS's self-referencing security
  group) is created by `azure-cluster-facts` instead and passed in as `cluster_asg_id`; this
  module's own NICs join it by id, exactly as `azure-node-pool`'s workers do — it does not create
  it, and does not re-export it.
- One `azurerm_virtual_machine_run_command` per node that delivers the `node-bootstrap` `on_node`
  bundle. Bootstrap runs on the node itself (Ansible `-c local`); secrets ride as protected
  parameters (injected as environment variables), so nothing sensitive lands in `custom_data` or
  state, and **no inbound port is opened** — the `deny-ssh` NSG rule (priority 100) stays. This is
  the same `az vm run-command` primitive the control-plane verb-scripts use.

## What this module never creates

VNets, subnets, or any other network fabric — pass an existing `vnet_name`/`subnet_name`.
Azure has no default VNet (unlike AWS), so both are always required.

## Known limitations

- **No `dns`/`static` endpoint_mode.** Unlike `aws-control-plane`, this module supports only the
  internal-LB registration endpoint — `dns`/`static` alternatives are out of scope and
  can be added later behind the same `endpoint_mode` variable name aws-control-plane already uses.
- **Single-region placement only.** All control-plane VMs land in `location`, spread across
  `availability_zones` — cross-region spread is out of scope (matches proxmox-control-plane's
  single-Proxmox-node limitation note).
- **No working example provided.** Azure validation is manual-tier — this repo has no
  live Azure subscription to test `init`/`plan`/`apply` against. `examples/basic/main.tf`
  is unverified beyond `tofu validate`.
