# proxmox-control-plane

Provisions the control-plane node(s) for a single-cluster RKE2 deployment on Proxmox.

## Join tokens and firewall ipset naming

This module generates its own cluster join tokens (`random_password` resources) and
exposes them as the `cluster_token`/`cluster_agent_token` outputs — there is no
separate cluster-facts unit to pre-generate them. `cluster_token` is consumed by this
module's own `node-bootstrap` calls (server-init and server-join alike);
`cluster_agent_token` is meant to be handed to `proxmox-node-pool`'s own
`cluster_agent_token` input by the consumer's Terragrunt config. There is no
Terraform-level dependency between the two sibling modules — only a value passed
through at that layer.

Similarly, the cluster-wide firewall ipset name
(`kube-compute-<cluster_name>-cluster`) is a plain deterministic-string
convention computed locally from `cluster_name`, not a shared output. `proxmox-node-pool`
computes the same formula independently to reference the cluster ipset by name.

## Replacing the first control-plane node

On a multi-node cluster, the first node looks for a live cluster at boot, before it starts etcd. If a peer answers, a replaced first node joins through it instead of starting a new etcd cluster.

- With static IPs, the first node probes the IP of every other control-plane node.
- With DHCP, the first node probes the cluster name `api.<cluster>.<domain>`. It resolves the name, skips its own IP, and probes each IP that remains.

This matches the AWS modules, where the first node probes `registration_address`.

The first node repeats the probe for about 60 seconds. A slow DNS answer or a booting peer then does not hide the live cluster. The node writes the IP that answered into its join address, not the name.

The wait costs time on every fresh multi-node boot, not only on a replacement. A new cluster has no live peer, so the first node waits the full 60 seconds before it starts etcd. The wait is bounded. A pass can run past 60 seconds, because a stale IP costs up to 10 seconds and a resolver can time out, but it cannot loop forever.

If no peer answers, the first node starts a new cluster. This happens when you replace the first node while every peer is down. Replace the first node last, with every peer healthy.

Any HTTPS service that answers at a probed IP can start a join attempt. A dead IP that DHCP hands to a different RKE2 cluster on the same network also answers. The join then loops on the token. There is no split brain, but the node does not form.

## Rolling to a new template

A new `proxmox_template_vm_id` reaches only new VMs and VMs that you replace. An apply does not replace the existing nodes, so their disks and etcd data stay. To move the existing nodes to the new template, replace them one at a time.

A replaced node gets a new disk. Delete its Kubernetes node first: RKE2 then removes its etcd member and accepts a new node with the same name.

The firewall of each node follows its own VM. When a VM is replaced, its firewall is replaced in the same apply.

Inside `proxmox-cluster`, put `module.control_plane.` before each address below.

> **Warning:** On a single-node cluster, a replaced node starts a new cluster. The cluster loses its data.

> **Warning:** Replace the first node last, with every peer healthy. If every peer is down, a replaced first node starts a new cluster.

1. Set `proxmox_template_vm_id` to the new template.
2. Run `tofu apply`. The plan must not replace a VM.
3. Select an additional node, for example key `"1"`, the second node.
4. Drain the node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
5. Delete the node: `kubectl delete node <node>`.
6. Replace the VM: `tofu apply -replace='proxmox_virtual_environment_vm.control_plane["1"]'`.

7. Verify that the node is `Ready`: `kubectl get nodes`.
8. Verify that every etcd pod is `Running`: `kubectl -n kube-system get pods -l component=etcd`.
9. If an additional node is still on the old template, go back to step 3.

> **Warning:** Replace the first node last, in its own apply. It rejoins through a peer, so every peer must be healthy.

10. Drain the first node, and then delete it, as in steps 4 and 5.
11. Replace the first node: `tofu apply -replace='proxmox_virtual_environment_vm.control_plane["0"]'`.
12. Do steps 7 and 8 again.
13. Roll the workers. See the `proxmox-node-pool` README.

Roll the control plane before the workers: a kubelet must not be newer than the API server.

## Proxmox pool and CPU weight

Both inputs are optional. Unset, the VMs join no pool and keep the Proxmox default CPU weight.

- `pool_id`: the Proxmox resource pool every control-plane VM joins. Set it when the API token is scoped to one pool.
- `cpu_units`: the CPU weight of each VM, from 1 to 262144. A lower weight gives CPU to other VMs when the host is busy.

## Cloud-init snippet upload

`cloud_init_upload_mode` is optional. It sets how the provider copies the cloud-init snippet files to the Proxmox host over SSH.

- Unset, the provider default (`stream`) applies. It opens a shell on the host and tries `sudo`.
- `sftp` uses the SFTP subsystem only. It does not use `sudo`, so the SSH user must have write permission on the snippets directory. Use it when the SSH user has no shell.
- Any other value is rejected.

The setting has no effect on image downloads, which use the API.

## Operational note: SSH connection bursts on apply

The `proxmox_virtual_environment_file` resources here (`vendor_data`, `node_init`,
`network_data`) upload cloud-init snippets via SSH — this is how the `bpg/proxmox`
provider handles snippet uploads, not something this module controls. Each upload opens
its own SSH connection, and OpenTofu's default per-unit parallelism (10) means a single
`apply` can already burst close to that many connections at once.

If a consumer applies this module concurrently with another unit that also does SSH
uploads — most commonly `proxmox-node-pool` against the same cluster — the combined
burst can exceed the Proxmox host's SSH daemon `MaxStartups` (OpenSSH default
`10:30:100`: begin randomly dropping unauthenticated connections once 10 are open at
once). The failure surfaces as a `bpg/proxmox` SSH auth error on an otherwise-valid
key/token (`ssh: unable to authenticate ... no supported methods remain`), lands on an
arbitrary resource, and is non-deterministic — some uploads in the same apply succeed,
others don't.

Two independent mitigations, not mutually exclusive:

- **Cap OpenTofu's per-unit parallelism** (e.g. `-parallelism=8` via consumer
  Terragrunt config). Only bounds a single unit — doesn't prevent two units applying
  concurrently from together exceeding the host's threshold.
- **Raise the Proxmox host's `MaxStartups`** in `/etc/ssh/sshd_config` (e.g.
  `MaxStartups 60:30:200`), then `sshd -t && systemctl reload ssh`. Scales with however
  many units a consumer applies concurrently, at the cost of a change outside version
  control on the Proxmox host itself.

Consumers that apply multiple Proxmox units concurrently (e.g. via a `run --all`-style
orchestrator) should expect to need the host-side change.

### Booting from a kube-images template

`proxmox_template_vm_id` is required. `node-bootstrap`'s cloud-init payload does not install RKE2: it
only configures and starts it, assuming the binaries are already on disk. A stock cloud
image has no RKE2, so the node would fail at `systemctl enable --now rke2-server.service`
while `tofu apply` reported success.

Set `proxmox_template_vm_id` to a pre-baked kube-images VM template's ID. Nodes are **full**-cloned from it, so they never
depend on the template surviving. The template carries OS prep, the RKE2 binaries
(both server and agent units — the role is chosen at launch), the SELinux policy, the
kernel modules, and the guest agent; this module supplies only per-cluster identity,
secrets, and join logic, as a cloud-init payload rendered by `node-bootstrap`.
Bootstrap runs asynchronously after `tofu apply` returns — tail
`/var/log/kube-compute-bootstrap.log` on the node to watch it.

The first control-plane node clones the platform ref (`gitops_platform_repo_url` at `gitops_platform_revision`) before RKE2 starts. It takes the Cilium and Argo CD manifests from `bootstrap/rendered/` in the clone. The template holds neither, but it must hold git. The inputs `argocd_manifest_url` and `argocd_manifest_sha256` are unused and will be removed. See [`node-bootstrap`](../node-bootstrap/README.md).

No check compares the template's contents with this module's inputs. The template's name is the documentation.

## A change to the user data of a running node

A change to any input of `node-bootstrap` (a rotated token, a new registry mirror, a
different platform revision) does not touch a running VM. The snippet on storage gets
the new content, and the VM keeps the file id it references. cloud-init reads user
data only at the first boot, so the running node does not apply the change.

To apply a change, replace the VM on purpose. The replaced VM boots with the current
snippet. Use the steps of "Rolling to a new template", from step 3: they drain the
node, replace an additional VM, verify it, and replace the first VM last. The
addresses are `module.<name>.proxmox_virtual_environment_vm.control_plane["0"]` for
the first VM and `module.<name>.proxmox_virtual_environment_vm.control_plane["1"]`
for the second.
Inside `proxmox-cluster`, put `module.control_plane.` before the resource type.

> **Warning:** Replacing a single-node cluster loses the cluster.

Do not replace several VMs in one apply: etcd loses its quorum.

