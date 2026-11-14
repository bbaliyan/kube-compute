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

See [proxmox-control-plane's
README](../proxmox-control-plane/README.md#operational-note-ssh-connection-bursts-on-apply)
— this module uploads the same kind of cloud-init snippets via the same `bpg/proxmox`
SSH mechanism. It is equally subject to the SSH connection burst / `MaxStartups`
interaction described there. It's most likely to surface when this module's apply overlaps
with `proxmox-control-plane`'s for the same cluster.


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

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | CIDR blocks allowed to reach ingress\_ports on this pool's workers from outside the cluster. Set on the pool that runs ingress. | `list(string)` | `[]` | no |
| <a name="input_cluster_agent_token"></a> [cluster\_agent\_token](#input\_cluster\_agent\_token) | Agent join token for this cluster, embedded in this pool's cloud-init. Take it from the cluster\_agent\_token output of the control plane at the consumer layer. Sensitive. | `string` | n/a | yes |
| <a name="input_cluster_domain"></a> [cluster\_domain](#input\_cluster\_domain) | DNS suffix matching the control plane's own cluster\_domain (e.g. 'cluster.example'). Required to compute the wildcard record's zone; ignored when dns\_server\_address is null. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster identity this pool joins. Must match the control plane's cluster\_name. | `string` | n/a | yes |
| <a name="input_desired_count"></a> [desired\_count](#input\_desired\_count) | Fixed pool size — every worker VM this pool creates. | `number` | `2` | no |
| <a name="input_disk_datastore_id"></a> [disk\_datastore\_id](#input\_disk\_datastore\_id) | Proxmox storage ID for worker VM disks and cloud-init drives. | `string` | `"local-lvm"` | no |
| <a name="input_dns_record_ttl"></a> [dns\_record\_ttl](#input\_dns\_record\_ttl) | TTL in seconds for the published wildcard record. Ignored when dns\_server\_address is null. Kept low by default — see proxmox-control-plane's dns\_record\_ttl for why a low TTL matters here (downstream resolver caching can otherwise stale-block a fresh apply for up to a full TTL). | `number` | `30` | no |
| <a name="input_dns_server_address"></a> [dns\_server\_address](#input\_dns\_server\_address) | Hostname or IPv4 address of an RFC2136-compliant DNS server to publish the wildcard record to. Null (default) skips DNS registration entirely; register the wildcard yourself in that case. | `string` | `null` | no |
| <a name="input_dns_server_port"></a> [dns\_server\_port](#input\_dns\_server\_port) | Port the DNS server accepts dynamic updates on. Ignored when dns\_server\_address is null. | `number` | `53` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | DNS nameserver addresses written into the cloud-init network-config of every VM. They also give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record. | `list(string)` | <pre>[<br/>  "1.1.1.1",<br/>  "8.8.8.8"<br/>]</pre> | no |
| <a name="input_dns_transport"></a> [dns\_transport](#input\_dns\_transport) | Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Ignored when dns\_server\_address is null. Defaults to 'udp'. See proxmox-control-plane's identical variable. | `string` | `"udp"` | no |
| <a name="input_extra_node_labels"></a> [extra\_node\_labels](#input\_extra\_node\_labels) | Additional node-label: entries for every worker in this pool. | `map(string)` | `{}` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_ingress_ports"></a> [ingress\_ports](#input\_ingress\_ports) | TCP ports opened from allowed\_ingress\_cidrs on this pool's workers, e.g. [80, 443] for Traefik. Never add 22 (SSH). | `list(number)` | `[]` | no |
| <a name="input_iso_datastore_id"></a> [iso\_datastore\_id](#input\_iso\_datastore\_id) | Proxmox storage ID for the OS image download and cloud-init snippet files. | `string` | `"local"` | no |
| <a name="input_manage_wildcard_dns_record"></a> [manage\_wildcard\_dns\_record](#input\_manage\_wildcard\_dns\_record) | Whether this pool publishes *.<cluster\_name> at its workers when DNS is configured. Only one pool of a cluster should, the one running ingress. | `bool` | `true` | no |
| <a name="input_network_bridge"></a> [network\_bridge](#input\_network\_bridge) | Proxmox Linux bridge every worker VM's NIC attaches to. | `string` | `"vmbr0"` | no |
| <a name="input_node_name_template"></a> [node\_name\_template](#input\_node\_name\_template) | Name for each worker of the pool: its VM name, hostname and Kubernetes node name. {number} becomes the worker's number as two digits (01, 02, ...) and is required. Null keeps <cluster\_name>-<pool\_name>-<n>, counting from 0. | `string` | `null` | no |
| <a name="input_node_taints"></a> [node\_taints](#input\_node\_taints) | Taints on every worker in this pool, each key=value:Effect. A label only lets pods be pinned here; a taint keeps every pod without a matching toleration off. | `list(string)` | `[]` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Installs OS updates daily with dnf-automatic, without rebooting. See node-bootstrap's own variable. | `bool` | `true` | no |
| <a name="input_pool_id"></a> [pool\_id](#input\_pool\_id) | Proxmox resource pool the worker VMs join. Null (default) puts them in no pool. A token scoped to one pool can only create VMs there. | `string` | `null` | no |
| <a name="input_pool_name"></a> [pool\_name](#input\_pool\_name) | Names this pool's VMs <cluster\_name>-<pool\_name>-<n> and labels every node kube-compute.io/node-group=<pool\_name>, which a nodeSelector can pin pods to. Distinct per pool, or two pools' VMs and snippets collide. | `string` | `"worker"` | no |
| <a name="input_proxmox_node"></a> [proxmox\_node](#input\_proxmox\_node) | Proxmox node name every worker VM in this pool is placed on. | `string` | n/a | yes |
| <a name="input_proxmox_template_vm_id"></a> [proxmox\_template\_vm\_id](#input\_proxmox\_template\_vm\_id) | VM ID of the kube-images Proxmox template to full-clone every worker from. A new value reaches only new or replaced VMs. Existing VMs keep their disks. To roll nodes one at a time, see 'Rolling to a new template' in the README. | `number` | n/a | yes |
| <a name="input_registration_address"></a> [registration\_address](#input\_registration\_address) | The address workers join through. Null (the default) computes genesis.<cluster\_name>.<cluster\_domain>, which needs cluster\_domain and dns\_server\_address. Set a literal IP only when DNS is not configured. Do not use cluster\_fqdn: a round-robin record can hang joins for 10 minutes or more. | `string` | `null` | no |
| <a name="input_registry_mirror_url"></a> [registry\_mirror\_url](#input\_registry\_mirror\_url) | Optional OCI registry mirror. Null = pull from upstream. | `string` | `null` | no |
| <a name="input_ssh_authorized_keys"></a> [ssh\_authorized\_keys](#input\_ssh\_authorized\_keys) | SSH public keys injected into the default cloud user via cloud-init. | `list(string)` | `null` | no |
| <a name="input_trusted_ca_pem"></a> [trusted\_ca\_pem](#input\_trusted\_ca\_pem) | Optional PEM cert(s) added to the worker's OS trust store. Null = none. Sensitive. | `string` | `null` | no |
| <a name="input_tsig_key_algorithm"></a> [tsig\_key\_algorithm](#input\_tsig\_key\_algorithm) | TSIG key algorithm: 'hmac-md5', 'hmac-sha1', 'hmac-sha256', or 'hmac-sha512'. Must match how the key was created on the DNS server. Ignored when dns\_server\_address is null. | `string` | `"hmac-sha256"` | no |
| <a name="input_tsig_key_name"></a> [tsig\_key\_name](#input\_tsig\_key\_name) | Name of the TSIG key configured on the DNS server, used to authenticate the dynamic update. Required when dns\_server\_address is set. | `string` | `null` | no |
| <a name="input_tsig_key_secret"></a> [tsig\_key\_secret](#input\_tsig\_key\_secret) | Base64-encoded TSIG shared secret. Required when dns\_server\_address is set. Sensitive — supply via a TF\_VAR\_* environment variable, never committed. | `string` | `null` | no |
| <a name="input_vm_cores"></a> [vm\_cores](#input\_vm\_cores) | Number of vCPU cores per worker VM. | `number` | n/a | yes |
| <a name="input_vm_cpu_type"></a> [vm\_cpu\_type](#input\_vm\_cpu\_type) | QEMU CPU model. | `string` | `"x86-64-v2-AES"` | no |
| <a name="input_vm_disk_gb"></a> [vm\_disk\_gb](#input\_vm\_disk\_gb) | Root disk size in GiB per worker VM. | `number` | n/a | yes |
| <a name="input_vm_memory_mb"></a> [vm\_memory\_mb](#input\_vm\_memory\_mb) | RAM per worker VM in MiB. | `number` | n/a | yes |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_node_provider"></a> [node\_provider](#output\_node\_provider) | Provider identifier the control-plane verb-scripts use to dispatch (Proxmox = direct SSH to the node). |
| <a name="output_pool_id"></a> [pool\_id](#output\_pool\_id) | Proxmox resource pool the workers join, or null when they join none. |
| <a name="output_wildcard_dns_registration_enabled"></a> [wildcard\_dns\_registration\_enabled](#output\_wildcard\_dns\_registration\_enabled) | Whether this pool published *.<cluster\_name> at its workers: manage\_wildcard\_dns\_record with both cluster\_domain and dns\_server\_address set. |
| <a name="output_worker_node_refs"></a> [worker\_node\_refs](#output\_worker\_node\_refs) | Map of worker VM name -> {instance\_id, ip, provider}. |
<!-- END_TF_DOCS -->
