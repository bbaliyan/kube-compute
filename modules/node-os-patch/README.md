# node-os-patch

OS-upgrade tooling for already-provisioned RKE2 nodes, shipped as part of kube-compute
so any consumer of these modules gets it without re-writing it themselves.

## What's here

A resource-less module: it creates nothing and runs nothing itself, it only renders a
script. `main.tf` templates
`templates/upgrade-os.sh.tftpl` into the `orchestrator_script` output — a
self-contained bash script, plain SSH, no Ansible/Ansible-core dependency. The caller
runs it themselves (`bash <(tofu output -raw orchestrator_script)`), on whatever
schedule they choose — OS patching is an operator-triggered action, not a
desired-state resource, so nothing here fires just because an unrelated `tofu apply`
touched this module's inputs.

The script, for each node in turn:

1. **Patch** — `dnf update -y` over SSH (retry + self-heal on transient dnf/rpm lock
   contention: 5 attempts, killing any stuck `dnf`/`rpm` process between retries),
   then `dnf needs-restarting -r` to check whether a reboot is actually needed. A
   node that doesn't need one is left alone — no unconditional reboot.
2. **Reboot** (only if needed) — captures `/proc/sys/kernel/random/boot_id`, triggers
   the reboot, and polls SSH every 10s (up to 600s) until the node is reachable again
   **and** its boot id has changed — confirms an actual new boot, not a stale
   connection that happened to reconnect. Then, if a systemd unit name was given
   (`rke2-server`/`rke2-agent`), polls `systemctl is-active` on it for up to 300s;
   non-fatal if it doesn't report active in that window — the run continues rather
   than aborting the whole rollout over one slow node.

Control-plane nodes are patched **one at a time** (`control_plane_node_refs`) —
etcd tolerates losing at most one control-plane node at once — then worker nodes
one at a time (`worker_node_refs`). An `all_in_one` cluster shape (no separate
worker pool) is the degenerate case: `worker_node_refs` defaults to `{}`, so the
rendered script's worker section is simply empty.

## Transport

Plain SSH, reusing `node-bootstrap`'s own already-working connection: the same
account/key node-bootstrap connects with (a deliberate, evidenced exception to this
project's usual no-SSH stance). **Proxmox-only today** — this module (and its
composition into `proxmox-cluster`) is the only provider path that currently wires
node refs into it.

## Verified live

Ran end-to-end against cluster-3's real control-plane nodes (the prior Ansible-based
version of this orchestrator): `dnf update -y` executed successfully over SSH,
confirming the per-node patch/reboot/RKE2-wait sequence works against a real
AlmaLinux target. The current plain-bash rewrite preserves that same sequence
node-for-node but has not yet been re-run live — confirm on a real cluster before
relying on it in production.
