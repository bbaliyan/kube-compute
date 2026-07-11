# azure-node-pool

A fixed-size node pool for a `azure-control-plane` cluster, pinned to a single availability zone
(one pool = one zone, matching `aws-node-pool`'s one-pool-per-subnet-per-AZ convention).
Backed by an `azurerm_linux_virtual_machine_scale_set` with `upgrade_mode = "Manual"` (no
autoscaling, no rolling upgrades — a fixed pool is the safe default for stateful workloads,
same rationale as `aws-node-pool`).

## Join flow

Every worker's system-assigned managed identity is granted `Key Vault Secrets User`,
scoped to exactly the control plane's `agent-token` secret (never the whole vault). At boot, the
worker fetches an OAuth token from Azure's Instance Metadata Service and calls the Key
Vault Secrets REST API directly via `curl` + `python3` — no Azure CLI dependency, since
the Ubuntu 26.04 image is not guaranteed to ship it.

## Firewall

This pool owns a small NSG of its own (deny-ssh at priority 100, allow-cluster-self at
priority 110), attached to every worker NIC — mirroring the control plane's firewall model.
Joining the control plane's `cluster_asg_id` (via `application_security_group_ids` on the NIC)
is only ASG *membership*, a label that NSG rules reference; on Azure it does not by
itself block or allow anything, so the pool's own NSG is what actually enforces
no-inbound-SSH and cluster-only east-west access on worker NICs.

## What this module never creates

VNets, subnets, or the cluster's Application Security Group — it joins the control plane's
`cluster_asg_id` by reference and creates no ASG of its own (only the node-scoped NSG
described above).

## Known limitations

- **No working example provided.** Azure validation is manual-tier — this repo has no
  live Azure subscription to test `init`/`plan`/`apply` against. `examples/basic/main.tf`
  is unverified beyond `tofu validate`.
- **One pool = one zone**, by design — spreading a single pool across zones is out of
  scope; create one `azure-node-pool` module instance per zone instead, same as
  `aws-node-pool`.
- **`registration_address` must resolve to a real address.** This module is intended to
  pair with an HA control plane (`control_plane_count > 1`), whose `registration_address` output
  is a real LB frontend IP. A control plane with `control_plane_count = 1` has no registration
  endpoint and exposes `registration_address = null`; wiring this module
  against such a control plane by passing that `null` through will not work. If you must pair
  this pool with a single-node control plane, pass that control plane's `cluster_ip` output explicitly
  instead of its `registration_address` output.
