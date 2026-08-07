# proxmox-node-pool

Provisions a pool of worker nodes for a single-cluster RKE2 deployment on Proxmox.

## Operational note: SSH connection bursts on apply

See [proxmox-control-plane's README](../proxmox-control-plane/README.md#operational-note-ssh-connection-bursts-on-apply)
— this module uploads the same kind of cloud-init snippets (`vendor_data`,
`node_init`, `network_data`) via the same `bpg/proxmox` SSH mechanism, and is
equally subject to the SSH connection burst / `MaxStartups` interaction described
there. It's most likely to surface here specifically when this module's apply overlaps
with `proxmox-control-plane`'s for the same cluster.

### Booting from a kube-image template

**A `proxmox_template_vm_id` template is now effectively required for a
working worker.** `node-bootstrap`'s cloud-init payload no longer installs
RKE2 — it only configures and starts it, on the assumption the binaries are
already on disk from a kube-image-baked template. `os_image_url`/
`os_image_file_id` (the stock-cloud-image path) still create a VM that
validates/applies cleanly, but the worker fails at
`systemctl enable --now rke2-agent.service` during first-boot cloud-init —
`tofu apply` succeeds while the worker never actually joins. Same
previously-undocumented consequence as `proxmox-control-plane`'s equivalent
note (see that module's README) — no more live Ansible install step anywhere
in `node-bootstrap`, on any provider. `os_image_url`/`os_image_file_id` remain
valid Terraform-level inputs for a plain, non-RKE2 VM; only "boot a working
RKE2 worker from a stock image" is gone.

Set `proxmox_template_vm_id` to a pre-baked kube-image VM template's ID instead
of `os_image_url`/`os_image_file_id`. Workers are **full**-cloned from it, so
they never depend on the template surviving. The template installs both RKE2
units; this pool's cloud-init payload enables only `rke2-agent`. Bootstrap runs
asynchronously on each worker after `tofu apply` returns — tail
`/var/log/kube-compute-bootstrap.log` on the node to watch it.

Changing any of `node-bootstrap`'s inputs after a worker's first boot has no
effect on that already-running worker — cloud-init reads its user-data once,
on first boot, and the rendered snippet is stable/reused rather than
triggering a VM replacement. Day-2 config changes need a new worker (replace).
