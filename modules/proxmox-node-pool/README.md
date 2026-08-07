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

Set `proxmox_template_vm_id` to a pre-baked kube-image VM template's ID instead
of `os_image_url`/`os_image_file_id`. Workers are **full**-cloned from it, so
they never depend on the template surviving. The template installs both RKE2
units; this pool's cloud-init payload enables only `rke2-agent`. Bootstrap runs
asynchronously on each worker after `tofu apply` returns — tail
`/var/log/kube-compute-bootstrap.log` on the node to watch it.
