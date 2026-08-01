# node-os-patch

OS-upgrade tooling for already-provisioned RKE2 nodes, shipped as part of kube-compute
so any consumer of these modules gets it without re-writing it themselves. Moved here
from the private kube-examples consumer repo (kube-claude wayfinder map
[#30](https://github.com/bbaliyan/kube-claude/issues/30)), which originally held it
deliberately (kube-claude map #14's ticket #19) before this module existed.

## What's here so far

`ansible/roles/os_patch/` — the per-node patch/reboot primitive, invoked over SSH
(the same account/key `node-bootstrap` itself connects with — a deliberate,
evidenced exception to CLAUDE.md's no-SSH constraint; see kube-claude map #14's notes
and map #26). This is the **single shared implementation**: `node-bootstrap`'s own
stage-0 first-boot OS update reaches it via a relative symlink
(`node-bootstrap/ansible/roles/os_patch` -> `../../../node-os-patch/ansible/roles/os_patch`),
rather than carrying an independent copy of the same `dnf update -y` logic (kube-claude
issue #35 wires that up).

- **`tasks/patch.yml`** — runs `dnf update -y` on the target node (retry + self-heal
  on transient dnf/rpm lock contention), then checks whether a reboot is actually
  needed (`dnf needs-restarting -r`, not an unconditional reboot). Sets
  `os_patch_reboot_needed: true|false` as a fact the caller branches on.
- **`tasks/reboot.yml`** — only does anything when `os_patch_reboot_needed` is true:
  reboots the node and waits for it to come back (`ansible.builtin.reboot` — the
  ansible-playbook process stays alive across the reboot and reconnects on its own
  over SSH), then waits for the node's RKE2 service (`os_patch_rke2_service`,
  caller-supplied — `rke2-server` or `rke2-agent` depending on the node's role) to
  report active before considering the step done.
- **`tasks/patch-and-reboot.yml`** — combines the two for one node, with the SSH
  connection vars scoped to the block (so a caller looping over nodes doesn't repeat
  them per task).

## Required variables

| Variable | Meaning |
|---|---|
| `os_patch_ansible_host` | IP address of the target node. |
| `os_patch_ansible_user` | SSH user (e.g. `almalinux`). |
| `os_patch_ansible_ssh_private_key_file` | Path to the SSH private key. |
| `os_patch_rke2_service` | `rke2-server` or `rke2-agent` — only needed by `reboot.yml`. |

## Not yet here

The generalized cross-node orchestrator (enumerate a cluster's nodes one-CP-at-a-time,
then workers, from Terraform's standardized `control_plane_node_refs`/
`worker_node_refs` outputs) is tracked separately — kube-claude issue
[#34](https://github.com/bbaliyan/kube-claude/issues/34) — and will add this module's
`.tf` files (it's a resource-less "data module" like `component-versions`, not an
apply-time-triggered action: OS patching is operator-triggered, never something that
should fire just because an unrelated `tofu apply` ran).

## Transport

SSH only, reusing `node-bootstrap`'s own already-working connection — chosen after a
Proxmox guest-agent API transport (`community.proxmox.proxmox_qemu_api`) was tried and
hit an unresolved `rpmdb open failed` error specific to that transport (kube-claude
issues #26-#29). AWS/Azure transport (SSM, and Azure's fundamentally different
`on_node`/run-command mode, which can't survive a mid-run reboot) is out of scope until
a live cluster exists there to validate against.

## Not verified live

No Proxmox connectivity in the environment these tasks were authored/moved in — syntax
validated (`ansible-playbook --syntax-check`), not run against a real VM yet. The
operator dry-runs against cluster-3 once the orchestrator (#34) and the kube-examples
migration (#36) land (kube-claude issue #37).
