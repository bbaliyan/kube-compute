# node-os-patch

OS-upgrade tooling for already-provisioned RKE2 nodes, shipped as part of kube-compute
so any consumer of these modules gets it without re-writing it themselves. Moved here
from the private kube-examples consumer repo (kube-claude wayfinder map
[#30](https://github.com/bbaliyan/kube-claude/issues/30)), which originally held it
deliberately (kube-claude map #14's ticket #19) before this module existed.

## What's here

`ansible/roles/os_patch/` — the per-node patch/reboot primitive, invoked over the same
connection `node-bootstrap` itself already established (SSH on Proxmox — the same
account/key node-bootstrap connects with, a deliberate, evidenced exception to
CLAUDE.md's no-SSH constraint, see kube-claude map #14's notes and map #26 — or AWS SSM
via `amazon.aws.aws_ssm`; see "Transport" below for how `reboot.yml` handles each). This
is the **single shared implementation**: `node-bootstrap`'s own stage-0 first-boot OS
update reaches it via a relative symlink (`node-bootstrap/ansible/roles/os_patch` ->
`../../../node-os-patch/ansible/roles/os_patch`).

- **`tasks/patch.yml`** — runs `dnf update -y` on the target node (retry + self-heal
  on transient dnf/rpm lock contention), then checks whether a reboot is actually
  needed (`dnf needs-restarting -r`, not an unconditional reboot). Sets
  `os_patch_reboot_needed: true|false` as a fact the caller branches on.
  Transport-agnostic — no special handling per connection type.
- **`tasks/reboot.yml`** — only does anything when `os_patch_reboot_needed` is true
  and `ansible_connection != "local"` (on_node-style transports, e.g. node-bootstrap's
  Azure mode, can't survive a mid-play reboot): reboots the node and waits for it to
  come back — the exact mechanism depends on the connection type, see "Transport"
  below — then, if `os_patch_rke2_service` was supplied, waits for that systemd unit to
  report active before considering the step done. `os_patch_rke2_service` is omitted by
  node-bootstrap's stage-0 call (RKE2 isn't installed yet at first boot), so that wait
  is skipped there.

`ansible/upgrade-os.yml` — the generalized cross-node orchestrator: registers each
node from `control_plane_node_refs`/`worker_node_refs` as a **real, named Ansible
host** (via `add_host`, not a "hosts: localhost" play with per-task connection
overrides — the latter makes every task's log output print `[localhost]`
indistinguishably regardless of which node actually ran, which is exactly what an
operator hit running this live and asked to have fixed), then drives `os_patch`
against `cp_nodes` one at a time (`serial: 1` — etcd tolerates losing at most one
control-plane node at once), then `worker_nodes` the same way. Consumed via this
module's own `orchestrator_playbook_path`/`orchestrator_extra_vars_json` outputs, not
invoked with hand-assembled extra-vars.

## Required variables (patch.yml / reboot.yml, called directly — e.g. by node-bootstrap)

| Variable | Meaning |
|---|---|
| `os_patch_rke2_service` | `rke2-server` or `rke2-agent` — only needed by `reboot.yml`, and only when RKE2 is already installed. |

`patch.yml`/`reboot.yml` otherwise rely on the caller's own Ansible connection
already being established (node-bootstrap's own `operator_connect`/`on_node` modes);
they take no `os_patch_ansible_host`/`_user`/`_ssh_private_key_file` variables — those
existed only for the orchestrator's old per-task connection-override approach, removed
along with `tasks/patch-and-reboot.yml` once `upgrade-os.yml` moved to `add_host`.

## Transport

SSH (Proxmox) and AWS SSM (`amazon.aws.aws_ssm`), reusing `node-bootstrap`'s own
already-working connection either way — chosen after a Proxmox guest-agent API
transport (`community.proxmox.proxmox_qemu_api`) was tried and hit an unresolved
`rpmdb open failed` error specific to that transport (kube-claude issues #26-#29).
Azure's fundamentally different `on_node`/run-command mode can't survive a mid-run
reboot at all — `reboot.yml` skips its whole block there (`ansible_connection ==
"local"`) rather than hanging or failing.

`patch.yml` (the `dnf update`/reboot-needed check) is transport-agnostic and needs no
special handling. `reboot.yml` branches by connection type: SSH uses
`ansible.builtin.reboot` directly (its reconnect-detection is built around SSH's
connect/disconnect semantics — verified live against Proxmox, see below). SSM does
**not** use that module — confirmed live against an AWS control-plane node (kube-claude
`kube-devclusters-migration` map) that `ansible.builtin.reboot`'s polling loop doesn't
reliably detect recovery over an SSM session (the instance rebooted and SSM reported
the agent back Online well inside the configured `reboot_timeout`, but the task never
noticed and hung indefinitely). SSM instead: fires the reboot async/fire-and-forget,
force-drops the now-stale connection (`meta: reset_connection`), then polls a real boot
marker (`/proc/sys/kernel/random/boot_id`) until it changes, with
`ignore_unreachable: true` on the poll task — required because Ansible otherwise drops
a host that goes UNREACHABLE for the rest of the *whole play*, not just that task, which
would abort on the very first connection attempt that catches the node still coming
back up.

## Verified live

Ran end-to-end against cluster-3's real control-plane nodes (kube-claude issue #37):
`dnf update -y` executed successfully over the SSH connection-override, confirming the
per-node primitive works against a real AlmaLinux target — but surfaced the
`[localhost]`-labeling problem above, fixed by moving to `add_host`. Full multi-node
sequencing (one-CP-at-a-time, then workers, with the `add_host`-based rewrite) not yet
re-verified live after that fix.

The SSM reboot-handling rewrite above (boot-id polling + `ignore_unreachable`) is
**not yet verified live** — it was written directly from the AWS control-plane hang
this section describes, syntax-checked and logic-tested locally (no AWS/SSM access
from the environment that wrote it), but has not yet completed a real reboot cycle
against an actual EC2 instance. Confirm it end-to-end before relying on it elsewhere.
