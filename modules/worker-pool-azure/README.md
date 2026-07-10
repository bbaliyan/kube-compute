# worker-pool-azure

A fixed-size worker pool for a `spine-azure` cluster, pinned to a single availability zone
(one pool = one zone, matching `worker-pool-aws`'s one-pool-per-subnet-per-AZ convention).
Backed by an `azurerm_linux_virtual_machine_scale_set` with `upgrade_mode = "Manual"` (no
autoscaling, no rolling upgrades — a fixed pool is the safe default for stateful workloads,
same rationale as `worker-pool-aws`).

## Join flow

Every worker's system-assigned managed identity is granted `Key Vault Secrets User`,
scoped to exactly the spine's `agent-token` secret (never the whole vault). At boot, the
worker fetches an OAuth token from Azure's Instance Metadata Service and calls the Key
Vault Secrets REST API directly via `curl` + `python3` — no Azure CLI dependency, since
the Ubuntu 26.04 image is not guaranteed to ship it.

## Firewall

This pool owns a small NSG of its own (deny-ssh at priority 100, allow-cluster-self at
priority 110), attached to every worker NIC — mirroring the spine's firewall model.
Joining the spine's `cluster_asg_id` (via `application_security_group_ids` on the NIC)
is only ASG *membership*, a label that NSG rules reference; on Azure it does not by
itself block or allow anything, so the pool's own NSG is what actually enforces
no-inbound-SSH and cluster-only east-west access on worker NICs.

## What this module never creates

VNets, subnets, or the cluster's Application Security Group — it joins the spine's
`cluster_asg_id` by reference and creates no ASG of its own (only the node-scoped NSG
described above).

## Known limitations

- **No working example provided.** Azure validation is manual-tier — this repo has no
  live Azure subscription to test `init`/`plan`/`apply` against. `examples/basic/main.tf`
  is unverified beyond `tofu validate`.
- **One pool = one zone**, by design — spreading a single pool across zones is out of
  scope; create one `worker-pool-azure` module instance per zone instead, same as
  `worker-pool-aws`.
- **`registration_address` must resolve to a real address.** This module is intended to
  pair with an HA spine (`control_plane_count > 1`), whose `registration_address` output
  is a real LB frontend IP. A spine with `control_plane_count = 1` has no registration
  endpoint and exposes `registration_address = null`; wiring this module
  against such a spine by passing that `null` through will not work. If you must pair
  this pool with a single-node spine, pass that spine's `cluster_ip` output explicitly
  instead of its `registration_address` output.
