# proxmox-node-pool

Provisions a pool of worker nodes for a single-cluster RKE2 deployment on Proxmox.

## Operational note: SSH connection bursts on apply

See [proxmox-control-plane's README](../proxmox-control-plane/README.md#operational-note-ssh-connection-bursts-on-apply)
— this module uploads the same kind of cloud-init snippets (`vendor_data`,
`hostname_init`, `network_data`) via the same `bpg/proxmox` SSH mechanism, and is
equally subject to the SSH connection burst / `MaxStartups` interaction described
there. It's most likely to surface here specifically when this module's apply overlaps
with `proxmox-control-plane`'s for the same cluster.
