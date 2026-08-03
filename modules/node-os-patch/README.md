# node-os-patch

OS-upgrade tooling for already-provisioned RKE2 nodes, shipped as part of kube-compute
so any consumer of these modules gets it without re-writing it themselves. Moved here
from the kube-examples consumer repo, which originally held it deliberately before this
module existed.

## What's here

`ansible/roles/os_patch/` — the per-node patch/reboot primitive, invoked over the same
connection `node-bootstrap` itself already established (SSH on Proxmox — the same
account/key node-bootstrap connects with, a deliberate, evidenced exception to this
project's usual no-SSH stance — or AWS SSM via `amazon.aws.aws_ssm`; see "Transport"
below for how `reboot.yml` handles each). This is the **single shared implementation**:
`node-bootstrap`'s own stage-0 first-boot OS update reaches it via a relative symlink
(`node-bootstrap/ansible/roles/os_patch` -> `../../../node-os-patch/ansible/roles/os_patch`).

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
`rpmdb open failed` error specific to that transport. Azure's fundamentally different
`on_node`/run-command mode can't survive a mid-run
reboot at all — `reboot.yml` skips its whole block there (`ansible_connection ==
"local"`) rather than hanging or failing.

`patch.yml` (the `dnf update`/reboot-needed check) is transport-agnostic and needs no
special handling. `reboot.yml` branches by connection type: SSH uses
`ansible.builtin.reboot` directly (its reconnect-detection is built around SSH's
connect/disconnect semantics — verified live against Proxmox, see below). SSM does
**not** use that module — confirmed live against a real AWS control-plane node that
`ansible.builtin.reboot`'s polling loop doesn't reliably detect recovery over an SSM
session (the instance rebooted and SSM reported the agent back Online well inside the
configured `reboot_timeout`, but the task never noticed and hung indefinitely).

SSM instead: fires the reboot async/fire-and-forget, then uses
`ansible.builtin.wait_for_connection` to detect recovery. A first attempt at this used a
hand-rolled `meta: reset_connection` right after triggering the reboot instead — also
tried live, and it failed worse: `amazon.aws.aws_ssm`'s own `reset()` calls
`start_session()` with no retry or exception-handling of its own, so calling it before
the instance had actually gone down raised an unhandled `AnsibleError` and crashed the
whole run rather than one task. `meta: reset_connection` also silently ignores `when:`
(Ansible warns "reset_connection task does not support when conditional"), so it
couldn't even be scoped to the non-SSH case alone. `wait_for_connection` calls that exact
same `connection.reset()` internally, but wrapped in `try/except` inside its own retry
loop — a reset attempt against a still-down instance is just a normal retry there, not a
crash. Once a working connection is confirmed, a real boot marker
(`/proc/sys/kernel/random/boot_id`) is compared against its pre-reboot value to confirm
the reconnect is an actual new boot, not a fluke — with `ignore_unreachable: true` on
that check too, since Ansible otherwise drops a host that goes UNREACHABLE for the rest
of the *whole play*, not just that task.

## Verified live

Ran end-to-end against cluster-3's real control-plane nodes:
`dnf update -y` executed successfully over the SSH connection-override, confirming the
per-node primitive works against a real AlmaLinux target — but surfaced the
`[localhost]`-labeling problem above, fixed by moving to `add_host`. Full multi-node
sequencing (one-CP-at-a-time, then workers, with the `add_host`-based rewrite) not yet
re-verified live after that fix.

The SSM reboot-handling logic above (`wait_for_connection` + boot-id confirmation) is
**not yet verified live**. It's the second iteration: the first (`meta: reset_connection`
+ boot-id polling) was tried against a real AWS control-plane node and crashed the whole
run, as described above. This second version was written directly from that crash,
syntax-checked and logic-tested locally (no AWS/SSM access from the environment that
wrote it), but has not yet completed a real reboot cycle against an actual EC2 instance.
Confirm it end-to-end before relying on it elsewhere — and if it fails live again, that's
real signal this mechanism needs rethinking further, not just another patch.
