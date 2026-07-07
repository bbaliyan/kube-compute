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

## What this module never creates

VNets, subnets, or the cluster's Application Security Group — it joins the spine's
`cluster_asg_id` by reference and creates no firewall object of its own.

## Known limitations

- **No working example provided.** Per issue 019's acceptance criteria, Azure validation
  is manual-tier — this repo has no live Azure subscription to test `init`/`plan`/`apply`
  against. `examples/basic/main.tf` is unverified beyond `tofu validate`.
- **One pool = one zone**, by design (see spine-azure design note 7) — spreading a single
  pool across zones is out of scope; create one `worker-pool-azure` module instance per
  zone instead, same as `worker-pool-aws`.
