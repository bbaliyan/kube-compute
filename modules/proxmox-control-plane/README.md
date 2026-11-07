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

Similarly, the cluster-wide and etcd-peer firewall ipset names
(`kube-compute-<cluster_name>-cluster` / `-etcd`) are a plain deterministic-string
convention computed locally from `cluster_name`, not a shared output. `proxmox-node-pool`
computes the same formula independently to reference the cluster ipset by name.

## Replacing the first control-plane node

On a multi-node cluster with static IPs, the first node probes the second node's IP at boot. If the cluster answers, a replaced first node rejoins it instead of starting a new etcd cluster. With DHCP, no peer IP is known before the first node exists, so there is no probe. Use `control_plane_ip_addresses` on a multi-node cluster.

The probe checks only the second node. Replace the first node only while the second node is healthy, and never in the same apply as the second node. Any HTTPS service that answers at the peer IP can start a join attempt, so the peer IP must belong to the second control-plane node only.

## Rolling to a new template

A new `proxmox_template_vm_id` reaches only new VMs and VMs that you replace. An apply does not replace the existing nodes, so their disks and etcd data stay. To move the existing nodes to the new template, replace them one at a time.

A replaced node gets a new disk. Delete its Kubernetes node first: RKE2 then removes its etcd member and accepts a new node with the same name.

The firewall of an additional node does not follow its VM by itself, so replace it in the same apply. The firewall of the first node follows its VM.

Inside `proxmox-cluster`, put `module.control_plane.` before each address below.

> **Warning:** On a single-node cluster, a replaced node starts a new cluster. The cluster loses its data.

> **Warning:** On a multi-node cluster with DHCP, a replaced first node starts a new etcd cluster. Do not replace the first node there.

1. Set `proxmox_template_vm_id` to the new template.
2. Run `tofu apply`. The plan must not replace a VM.
3. Select an additional node, for example key `"1"`, the second node.
4. Drain the node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
5. Delete the node: `kubectl delete node <node>`.
6. Replace the VM and its firewall:

   ```sh
   tofu apply \
     -replace='proxmox_virtual_environment_vm.control_plane_additional["1"]' \
     -replace='proxmox_virtual_environment_firewall_options.control_plane["1"]' \
     -replace='proxmox_virtual_environment_firewall_rules.control_plane["1"]'
   ```

7. Verify that the node is `Ready`: `kubectl get nodes`.
8. Verify that every etcd pod is `Running`: `kubectl -n kube-system get pods -l component=etcd`.
9. If an additional node is still on the old template, go back to step 3.

> **Warning:** Replace the first node last, in its own apply. It rejoins through the second node, so the second node must be healthy.

10. Drain the first node, and then delete it, as in steps 4 and 5.
11. Replace the first node: `tofu apply -replace='proxmox_virtual_environment_vm.control_plane'`.
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

**A `proxmox_template_vm_id` template is now effectively required for a working
cluster.** `node-bootstrap`'s cloud-init payload no longer installs RKE2 — it only
configures and starts it, assuming the binaries are already on disk. That assumption
only holds for a kube-images-baked template. Setting `os_image_url`/`os_image_file_id`
alone (the plain stock-cloud-image path) still creates a VM and still
validates/applies cleanly, but the node fails at
`systemctl enable --now rke2-server.service` during first-boot cloud-init —
`tofu apply` reports success while the cluster never actually comes up. Same cause on
every provider (no more live Ansible install step anywhere in `node-bootstrap` — see
`../node-bootstrap/README.md`). `os_image_url`/`os_image_file_id` remain valid
Terraform-level inputs for a plain, non-RKE2 VM; only "boot a working RKE2 node from a
stock image" is gone.

Set `proxmox_template_vm_id` to a pre-baked kube-images VM template's ID instead of
`os_image_url`/`os_image_file_id`. Nodes are **full**-cloned from it, so they never
depend on the template surviving. The template carries OS prep, the RKE2 binaries
(both server and agent units — the role is chosen at launch), the SELinux policy, the
kernel modules, and the guest agent; this module supplies only per-cluster identity,
secrets, and join logic, as a cloud-init payload rendered by `node-bootstrap`.
Bootstrap runs asynchronously after `tofu apply` returns — tail
`/var/log/kube-compute-bootstrap.log` on the node to watch it. No compatibility check
is made between the template's contents and `k8s_version`/`cilium_version`/
`argocd_version`; the template's self-describing name is the documentation.

## A change to the user data of a running node

A change to any input of `node-bootstrap` (a rotated token, a new registry mirror, a
different platform revision) does not touch a running VM. The snippet on storage gets
the new content, and the VM keeps the file id it references. cloud-init reads user
data only at the first boot, so the running node does not apply the change.

To apply a change, replace the VM on purpose. The replaced VM boots with the current
snippet. Use the steps of "Rolling to a new template", from step 3: they drain the
node, replace an additional VM with its firewall, verify it, and replace the first VM
last. The addresses are `module.<name>.proxmox_virtual_environment_vm.control_plane`
and `module.<name>.proxmox_virtual_environment_vm.control_plane_additional["1"]`.
Inside `proxmox-cluster`, put `module.control_plane.` before the resource type.

> **Warning:** Replacing a single-node cluster loses the cluster.

Do not replace several VMs in one apply: etcd loses its quorum.

