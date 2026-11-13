# proxmox-node-pool

Provisions a pool of worker nodes for a single-cluster RKE2 deployment on Proxmox.

## Pool name, labels and taints

`pool_name` (default `worker`) names the pool's VMs `<cluster_name>-<pool_name>-<n>` and
labels every node `kube-compute.io/node-group=<pool_name>`, which a nodeSelector can
pin pods to. Pools of the same cluster need distinct names, or their VMs and snippets
collide. `node_taints` keeps every pod without a matching toleration off the pool.

The pool that runs ingress sets `allowed_ingress_cidrs` and `ingress_ports`, which open
those ports on its workers. It also keeps `manage_wildcard_dns_record` on so the wildcard
record points at them. Every other pool of the cluster turns the record off.

## Rolling to a new template

A new `proxmox_template_vm_id` reaches only new workers and workers that you replace. An apply does not replace the existing workers. To move them to the new template, replace them one at a time. The firewall of a worker follows its VM.

Roll the control plane first. See the `proxmox-control-plane` README. Inside `proxmox-cluster`, put `module.node_pools["<pool>"].` before the address below.

1. Set `proxmox_template_vm_id` to the new template.
2. Run `tofu apply`. The plan must not replace a VM.
3. Select a worker, for example key `"0"`, the first worker.
4. Drain the worker: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
5. Delete the worker: `kubectl delete node <node>`.
6. Replace the worker: `tofu apply -replace='proxmox_virtual_environment_vm.worker["0"]'`.
7. Verify that the worker is `Ready`: `kubectl get nodes`.
8. If a worker is still on the old template, go back to step 3.

## Join token and firewall ipset naming

This pool takes `cluster_agent_token` as a plain input variable — pass it the value of
`proxmox-control-plane`'s own `cluster_agent_token` output via the consumer's
Terragrunt config. There is no Terraform-level dependency between the two sibling
modules, and this pool never generates or owns a token itself.

The cluster-wide firewall ipset name it references (`kube-compute-<cluster_name>-cluster`)
is a plain deterministic-string convention computed locally from `cluster_name`. It is
identical to the formula `proxmox-control-plane` uses to name the ipset it actually
creates. This pool never creates the ipset itself, only references it by name.

## Proxmox pool

`pool_id` is optional. Unset, the VMs join no pool.

- `pool_id`: the Proxmox resource pool every worker joins. Set it when the API token is scoped to one pool. It is not `pool_name`, which names the node group.

## Operational note: SSH connection bursts on apply

See [proxmox-control-plane's README](../proxmox-control-plane/README.md#operational-note-ssh-connection-bursts-on-apply)
— this module uploads the same kind of cloud-init snippets via the same `bpg/proxmox` SSH mechanism. It is equally subject to the SSH connection burst / `MaxStartups` interaction described there. It's most likely to surface when this module's apply
overlaps with `proxmox-control-plane`'s for the same cluster.

### Booting from a kube-images template

`proxmox_template_vm_id` is required. `node-bootstrap`'s cloud-init payload does not install RKE2: it
only configures and starts it, assuming the binaries are already on disk. A stock cloud
image has no RKE2, so the worker would fail at `systemctl enable --now rke2-agent.service`
while `tofu apply` reported success.

Set `proxmox_template_vm_id` to a pre-baked kube-images VM template's ID. Workers are **full**-cloned from it, so they never
depend on the template surviving. The template installs both RKE2 units; this pool's
cloud-init payload enables only `rke2-agent`. Bootstrap runs asynchronously on each
worker after `tofu apply` returns — tail `/var/log/kube-compute-bootstrap.log` on the
node to watch it.

Changing any of `node-bootstrap`'s inputs after a worker's first boot has no effect on
that already-running worker. Cloud-init reads its user-data once, on first boot, and the
rendered snippet is stable/reused rather than triggering a VM replacement. Day-2 config
changes need a new worker (replace).
