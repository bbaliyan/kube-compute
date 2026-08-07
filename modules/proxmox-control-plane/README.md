# proxmox-control-plane

Provisions the control-plane node(s) for a single-cluster RKE2 deployment on Proxmox.

## Operational note: SSH connection bursts on apply

The `proxmox_virtual_environment_file` resources here (`vendor_data`, `node_init`,
`network_data`) upload cloud-init snippets via SSH — this is how the `bpg/proxmox`
provider handles snippet uploads, not something this module controls. Each upload opens
its own SSH connection to the Proxmox node, and OpenTofu's default per-unit resource
parallelism (10) means a single `apply` of this module can already burst close to that
many connections at once.

If a consumer applies this module concurrently with another unit that also does SSH
uploads — most commonly `proxmox-node-pool` against the same cluster — the combined
burst can exceed the Proxmox host's SSH daemon `MaxStartups` (OpenSSH's default is
`10:30:100`: begin randomly dropping unauthenticated connections once 10 are open at
once). The failure surfaces as a `bpg/proxmox` SSH auth error on an otherwise-valid
key/token (`ssh: unable to authenticate ... no supported methods remain`), lands on an
arbitrary resource, and is non-deterministic — some uploads in the same apply succeed,
others don't.

Two independent mitigations, not mutually exclusive:

- **Cap OpenTofu's per-unit parallelism** (e.g. `-parallelism=8` via consumer
  Terragrunt config) to reduce how many connections one unit can open at once. This
  only bounds a single unit — it doesn't prevent two units applying at the same time
  from together exceeding the host's threshold.
- **Raise the Proxmox host's `MaxStartups`** in `/etc/ssh/sshd_config` (e.g.
  `MaxStartups 60:30:200`), then `sshd -t && systemctl reload ssh`. This scales with
  however many units a consumer applies concurrently, independent of per-unit
  parallelism tuning, at the cost of a change outside version control on the Proxmox
  host itself.

Consumers that apply multiple Proxmox units concurrently (e.g. via a `run --all`-style
orchestrator) should expect to need the host-side change.

### Booting from a kube-image template

**A `proxmox_template_vm_id` template is now effectively required for a working
cluster.** `node-bootstrap`'s cloud-init payload no longer installs RKE2 — it
only configures and starts it, on the assumption the binaries are already on
disk. That assumption only holds for a kube-image-baked template. Setting
`os_image_url`/`os_image_file_id` alone (the plain stock-cloud-image path)
still creates a VM and still validates/applies cleanly, but the node will fail
at `systemctl enable --now rke2-server.service` during first-boot cloud-init —
`tofu apply` reports success while the cluster never actually comes up. This
is a direct, previously-undocumented consequence of the same node-bootstrap
cutover that intentionally left `aws-control-plane`/`azure-control-plane`
non-functional (see `../node-bootstrap/README.md`) — Proxmox's own stock-image
path is just as affected, for the identical reason (no more live Ansible
install step anywhere). `os_image_url`/`os_image_file_id` remain supported at
the Terraform level (unchanged variables, no new validation added) so a
consumer who needs a plain, non-RKE2 Proxmox VM for some other purpose is
unaffected — only "boot a working RKE2 node from a stock image" is gone.

Set `proxmox_template_vm_id` to a pre-baked kube-image VM template's ID instead
of `os_image_url`/`os_image_file_id`. Nodes are **full**-cloned from it, so they
never depend on the template surviving. The template carries OS prep, the RKE2
binaries (both the server and agent units — the role is chosen at launch), the
SELinux policy, the kernel modules, and the guest agent; this module supplies
only per-cluster identity, secrets, and join logic, as a cloud-init payload
rendered by `node-bootstrap`. Bootstrap runs asynchronously on the node after
`tofu apply` returns — tail `/var/log/kube-compute-bootstrap.log` on the node
to watch it. No compatibility check is made between the template's contents and
`k8s_version`/`cilium_version`/`argocd_version`; the template's self-describing
name is the documentation.

Changing any of `node-bootstrap`'s inputs (a rotated token, a new registry
mirror, a different platform revision) after a node's first boot has no effect
on that already-running node — cloud-init only ever reads its user-data once,
on first boot, and the rendered snippet file is stable/reused rather than
triggering a VM replacement. Day-2 config changes need a new node (replace),
not a `tofu apply` on the existing one.
