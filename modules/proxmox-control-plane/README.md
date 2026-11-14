# proxmox-control-plane

Provisions the control-plane node(s) for a single-cluster RKE2 deployment on Proxmox.

## Join tokens and firewall ipset naming

This module generates its own cluster join tokens (`random_password` resources) and
exposes them as the `cluster_token`/`cluster_agent_token` outputs. There is no separate
cluster-facts unit to pre-generate them. `cluster_token` is consumed by this module's own
`node-bootstrap` calls (server-init and server-join alike). The consumer's Terragrunt
config is meant to hand `cluster_agent_token` to `proxmox-node-pool`'s own
`cluster_agent_token` input. There is no Terraform-level dependency between the two
sibling modules — only a value passed through at that layer.


Similarly, the cluster-wide firewall ipset name
(`kube-compute-<cluster_name>-cluster`) is a plain deterministic-string
convention computed locally from `cluster_name`, not a shared output. `proxmox-node-pool`
computes the same formula independently to reference the cluster ipset by name.

## Replacing the first control-plane node

On a multi-node cluster, the first node looks for a live cluster at boot, before it starts etcd. If a peer answers, a replaced first node joins through it instead of starting a new etcd cluster.

The first node probes the cluster name `api.<cluster>.<domain>`. It resolves the name, skips its own IP, and probes each IP that remains.

This matches the AWS modules, where the first node probes `registration_address`.

The first node repeats the probe for about 60 seconds. A slow DNS answer or a booting peer then does not hide the live cluster. The node writes the IP that answered into its join address, not the name.

The wait costs time on every fresh multi-node boot, not only on a replacement. A new cluster has no live peer, so the first node waits the full 60 seconds before it starts etcd. The wait is bounded. A pass can run past 60 seconds, because a stale IP costs up to 10 seconds and a resolver can time out. It cannot loop forever.

If no peer answers, the first node starts a new cluster. This happens when you replace the first node while every peer is down. Replace the first node last, with every peer healthy.

Any HTTPS service that answers at a probed IP can start a join attempt. A dead IP that the DHCP server hands to a different RKE2 cluster on the same network also answers. The join then loops on the token. There is no split brain, but the node does not form.

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

## Proxmox pool

`pool_id` is optional. Unset, the VMs join no pool.

- `pool_id`: the Proxmox resource pool every control-plane VM joins. Set it when the API token is scoped to one pool.

## Operational note: SSH connection bursts on apply

The `proxmox_virtual_environment_file` resources here (`vendor_data`, `node_init`,
`network_data`) upload cloud-init snippets via SSH. This is how the `bpg/proxmox` provider
handles snippet uploads, not something this module controls. Each upload opens its own SSH
connection. OpenTofu's default per-unit parallelism (10) means a single `apply` can
already burst close to that many connections at once.

Another unit that also does SSH uploads can run at the same time as this module. The most
common case is `proxmox-node-pool` against the same cluster. Then the combined burst can
exceed the Proxmox host's SSH daemon `MaxStartups`. The OpenSSH default is `10:30:100`,
which begins randomly dropping unauthenticated connections once 10 are open at once. The
failure surfaces as a `bpg/proxmox` SSH auth error on an otherwise-valid key/token (`ssh:
unable to authenticate ... no supported methods remain`). It lands on an arbitrary
resource and is non-deterministic. Some uploads in the same apply succeed, others don't.

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

Set `proxmox_template_vm_id` to a pre-baked kube-images VM template's ID. Nodes are
**full**-cloned from it, so they never depend on the template surviving. The template
carries OS prep, the RKE2 binaries, the SELinux policy, the kernel modules, and the guest
agent. It holds both the server and agent units, because the role is chosen at launch.
This module supplies only per-cluster identity, secrets, and join logic, as a cloud-init
payload rendered by `node-bootstrap`. Bootstrap runs asynchronously after `tofu apply`
returns — tail `/var/log/kube-compute-bootstrap.log` on the node to watch it.


The first control-plane node clones the platform ref (`gitops_platform_repo_url` at `gitops_platform_revision`) before RKE2 starts. It takes the Cilium and Argo CD manifests from `bootstrap/rendered/` in the clone. The template holds neither, but it must hold git. See [`node-bootstrap`](../node-bootstrap/README.md).

No check compares the template's contents with this module's inputs. The template's name is the documentation.

## A change to the user data of a running node

A change to any input of `node-bootstrap` (a rotated token, a new registry mirror, a
different platform revision) does not touch a running VM. The snippet on storage gets
the new content, and the VM keeps the file id it references. cloud-init reads user
data only at the first boot, so the running node does not apply the change.

To apply a change, replace the VM on purpose. The replaced VM boots with the current
snippet. Use the steps of "Rolling to a new template", from step 3. They drain the node,
replace an additional VM, verify it, and replace the first VM last. The addresses are
`module.<name>.proxmox_virtual_environment_vm.control_plane["0"]` for the first VM and
`module.<name>.proxmox_virtual_environment_vm.control_plane["1"]` for the second. Inside
`proxmox-cluster`, put `module.control_plane.` before the resource type.

> **Warning:** Replacing a single-node cluster loses the cluster.

Do not replace several VMs in one apply: etcd loses its quorum.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allowed_ingress_cidrs"></a> [allowed\_ingress\_cidrs](#input\_allowed\_ingress\_cidrs) | CIDR blocks allowed inbound to the cluster ports from outside the cluster — the networks you administer/reach the cluster from. Required — environment-specific. | `list(string)` | n/a | yes |
| <a name="input_cert_mode"></a> [cert\_mode](#input\_cert\_mode) | Certificate issuer mode deployed by kube-platform. 'selfsigned' (default), 'byo', or 'acme'. | `string` | `"selfsigned"` | no |
| <a name="input_cluster_domain"></a> [cluster\_domain](#input\_cluster\_domain) | DNS suffix (e.g. 'cluster.example'). When set, the FQDN is api.<cluster\_name>.<cluster\_domain> and the wildcard is *.<cluster\_name>.<cluster\_domain>. Required when control\_plane\_count > 1. | `string` | `null` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster identity. Used in VM names, tags, FQDN, and the kubeconfig SAN. Lowercase, starts with a letter. | `string` | n/a | yes |
| <a name="input_cluster_network_cidr"></a> [cluster\_network\_cidr](#input\_cluster\_network\_cidr) | CIDR of the cluster's L2 subnet (e.g. '192.168.1.0/24'). It is the only member of the cluster firewall ipset. Required when control\_plane\_count > 1 or when any node pool attaches. | `string` | `null` | no |
| <a name="input_cluster_type"></a> [cluster\_type](#input\_cluster\_type) | Cluster topology: 'all\_in\_one' (control-plane nodes stay schedulable) or 'dedicated\_control\_plane' (control-plane nodes are tainted, so workloads run only on node pools). The module cannot derive this from the worker count, because node pools are separate state. | `string` | `"all_in_one"` | no |
| <a name="input_control_plane_count"></a> [control\_plane\_count](#input\_control\_plane\_count) | Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain. | `number` | `1` | no |
| <a name="input_disk_datastore_id"></a> [disk\_datastore\_id](#input\_disk\_datastore\_id) | Proxmox storage ID for VM disks and cloud-init drives. Must support 'images' content type. | `string` | `"local-lvm"` | no |
| <a name="input_dns_record_ttl"></a> [dns\_record\_ttl](#input\_dns\_record\_ttl) | TTL in seconds for the published cluster\_fqdn record and the genesis node's self-registered record. Ignored when dns\_server\_address is null. Keep it low; see proxmox-boot-steps' dns\_self\_register\_ttl. | `number` | `30` | no |
| <a name="input_dns_server_address"></a> [dns\_server\_address](#input\_dns\_server\_address) | Hostname or IPv4 address of an RFC2136-compliant DNS server to publish cluster\_fqdn to (any server that speaks RFC2136 — not tied to a specific product). Null (default) skips DNS registration entirely; register wildcard\_dns\_name/cluster\_fqdn yourself in that case. | `string` | `null` | no |
| <a name="input_dns_server_port"></a> [dns\_server\_port](#input\_dns\_server\_port) | Port the DNS server accepts dynamic updates on. Ignored when dns\_server\_address is null. | `number` | `53` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | DNS nameserver addresses written into the cloud-init network-config of every VM. They also give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record. | `list(string)` | <pre>[<br/>  "1.1.1.1",<br/>  "8.8.8.8"<br/>]</pre> | no |
| <a name="input_dns_transport"></a> [dns\_transport](#input\_dns\_transport) | Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Ignored when dns\_server\_address is null. Defaults to 'udp'. Some DNS servers drop a TCP update mid-way. A few IPv4 addresses in one A record set fit well under the UDP message-size limit. | `string` | `"udp"` | no |
| <a name="input_extra_server_manifests"></a> [extra\_server\_manifests](#input\_extra\_server\_manifests) | Forwarded verbatim to node-bootstrap's own identically-named variable, on the genesis (server-init) node only — since RKE2's manifest auto-deploy only needs to apply once per cluster. Empty by default. | `map(string)` | `{}` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional Proxmox VM tags applied to every control-plane VM, and forwarded to cloud-init's platform Application (helm.valuesObject.extraTags). | `map(string)` | `{}` | no |
| <a name="input_gitops_platform_enabled"></a> [gitops\_platform\_enabled](#input\_gitops\_platform\_enabled) | Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application. | `bool` | `true` | no |
| <a name="input_gitops_platform_repo_url_override"></a> [gitops\_platform\_repo\_url\_override](#input\_gitops\_platform\_repo\_url\_override) | Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin. | `string` | `null` | no |
| <a name="input_gitops_platform_revision_override"></a> [gitops\_platform\_revision\_override](#input\_gitops\_platform\_revision\_override) | Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default. | `string` | `null` | no |
| <a name="input_gitops_workloads_path"></a> [gitops\_workloads\_path](#input\_gitops\_workloads\_path) | Path within the workloads repo Argo CD applies. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"."` | no |
| <a name="input_gitops_workloads_repo_url"></a> [gitops\_workloads\_repo\_url](#input\_gitops\_workloads\_repo\_url) | Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application. | `string` | `null` | no |
| <a name="input_gitops_workloads_revision"></a> [gitops\_workloads\_revision](#input\_gitops\_workloads\_revision) | Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"main"` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet holds up an OS shutdown to evict pods. See node-bootstrap's own variable; null disables it. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_ingress_ports"></a> [ingress\_ports](#input\_ingress\_ports) | TCP ports opened from allowed\_ingress\_cidrs on every control-plane VM: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH). | `list(number)` | <pre>[<br/>  80,<br/>  443,<br/>  6443<br/>]</pre> | no |
| <a name="input_iscsi_initiator_prefix"></a> [iscsi\_initiator\_prefix](#input\_iscsi\_initiator\_prefix) | Prefix of the fixed iSCSI initiator name, in the form iqn.<yyyy-mm>.<reversed domain>, for example iqn.2026-01.test.example. A node writes <prefix>:<cluster\_name>-<node label>, so a target can allow-list it before a rebuild. Null keeps the OS name. The image needs iscsi-initiator-utils. | `string` | `null` | no |
| <a name="input_iso_datastore_id"></a> [iso\_datastore\_id](#input\_iso\_datastore\_id) | Proxmox storage ID for the OS image download and cloud-init snippet files. Must support 'iso', 'snippets', and 'import' content types. | `string` | `"local"` | no |
| <a name="input_manage_wildcard_dns_record"></a> [manage\_wildcard\_dns\_record](#input\_manage\_wildcard\_dns\_record) | Whether this module publishes *.<cluster\_name> at the control plane on an all\_in\_one cluster. false leaves the record to the pool that runs ingress. | `bool` | `true` | no |
| <a name="input_network_bridge"></a> [network\_bridge](#input\_network\_bridge) | Proxmox Linux bridge every control-plane VM's NIC attaches to. The module never creates bridges — pass an existing one. | `string` | `"vmbr0"` | no |
| <a name="input_node_name_template"></a> [node\_name\_template](#input\_node\_name\_template) | Name for each control-plane node: its VM name, hostname and Kubernetes node name. {number} becomes the node's number as two digits (01, 02, ...) and is required. Null keeps <cluster\_name>-cp-<n>, counting from 0. | `string` | `null` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Installs OS updates daily with dnf-automatic, without rebooting. See node-bootstrap's own variable. | `bool` | `true` | no |
| <a name="input_platform_extra_helm_parameters"></a> [platform\_extra\_helm\_parameters](#input\_platform\_extra\_helm\_parameters) | Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. | `map(string)` | `{}` | no |
| <a name="input_platform_helm_values_object"></a> [platform\_helm\_values\_object](#input\_platform\_helm\_values\_object) | Arbitrary object forwarded to the platform Application as helm.valuesObject. | `any` | `null` | no |
| <a name="input_pool_id"></a> [pool\_id](#input\_pool\_id) | Proxmox resource pool the control-plane VMs join. Null (default) puts them in no pool. A token scoped to one pool can only create VMs there. | `string` | `null` | no |
| <a name="input_proxmox_node"></a> [proxmox\_node](#input\_proxmox\_node) | Proxmox node name every control-plane VM is placed on (the hostname shown in the Proxmox UI under Datacenter). Cross-host spread for HA is a future enhancement — all control-plane VMs land on this one Proxmox node today. | `string` | n/a | yes |
| <a name="input_proxmox_template_vm_id"></a> [proxmox\_template\_vm\_id](#input\_proxmox\_template\_vm\_id) | VM ID of the kube-images Proxmox template to full-clone every control-plane node from. A new value reaches only new or replaced VMs. Existing VMs keep their disks. To roll nodes one at a time, see 'Rolling to a new template' in the README. | `number` | n/a | yes |
| <a name="input_registry_mirror_url"></a> [registry\_mirror\_url](#input\_registry\_mirror\_url) | Optional OCI registry mirror (Nexus/Harbor/Artifactory/any). Null = pull from upstream. | `string` | `null` | no |
| <a name="input_ssh_authorized_keys"></a> [ssh\_authorized\_keys](#input\_ssh\_authorized\_keys) | SSH public keys injected into the default cloud user via the Proxmox cloud-init drive, for out-of-band VM access. Null = no keys injected. | `list(string)` | `null` | no |
| <a name="input_trusted_ca_pem"></a> [trusted\_ca\_pem](#input\_trusted\_ca\_pem) | Optional PEM cert(s) added to the node OS trust store. Null = none. Sensitive. | `string` | `null` | no |
| <a name="input_tsig_key_algorithm"></a> [tsig\_key\_algorithm](#input\_tsig\_key\_algorithm) | TSIG key algorithm: 'hmac-md5', 'hmac-sha1', 'hmac-sha256', or 'hmac-sha512'. Must match how the key was created on the DNS server. Ignored when dns\_server\_address is null. | `string` | `"hmac-sha256"` | no |
| <a name="input_tsig_key_name"></a> [tsig\_key\_name](#input\_tsig\_key\_name) | Name of the TSIG key configured on the DNS server, used to authenticate the dynamic update. Required when dns\_server\_address is set. | `string` | `null` | no |
| <a name="input_tsig_key_secret"></a> [tsig\_key\_secret](#input\_tsig\_key\_secret) | Base64-encoded TSIG shared secret. Required when dns\_server\_address is set. Sensitive — supply via a TF\_VAR\_* environment variable, never committed. | `string` | `null` | no |
| <a name="input_vm_cores"></a> [vm\_cores](#input\_vm\_cores) | Number of vCPU cores per control-plane VM. | `number` | n/a | yes |
| <a name="input_vm_cpu_type"></a> [vm\_cpu\_type](#input\_vm\_cpu\_type) | QEMU CPU model. 'x86-64-v2-AES' (default) enables live migration between different CPU generations. | `string` | `"x86-64-v2-AES"` | no |
| <a name="input_vm_disk_gb"></a> [vm\_disk\_gb](#input\_vm\_disk\_gb) | Root disk size in GiB per control-plane VM. | `number` | n/a | yes |
| <a name="input_vm_memory_mb"></a> [vm\_memory\_mb](#input\_vm\_memory\_mb) | RAM per control-plane VM in MiB. | `number` | n/a | yes |
| <a name="input_workloads_extra_helm_parameters"></a> [workloads\_extra\_helm\_parameters](#input\_workloads\_extra\_helm\_parameters) | Helm parameters forwarded verbatim to the workloads Application. See node-bootstrap for full description. | `map(string)` | `{}` | no |
| <a name="input_workloads_helm_values_object"></a> [workloads\_helm\_values\_object](#input\_workloads\_helm\_values\_object) | Arbitrary object forwarded to the workloads Application as helm.valuesObject. Use for values a map(string) cannot carry, such as a pod's tolerations. | `any` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_cluster_agent_token"></a> [cluster\_agent\_token](#output\_cluster\_agent\_token) | Separate shared secret accepted only from agents (config.yaml agent-token), generated by this module. Pass it to the cluster\_agent\_token input of proxmox-node-pool at the consumer layer. The two modules do not depend on each other. |
| <a name="output_cluster_fqdn"></a> [cluster\_fqdn](#output\_cluster\_fqdn) | API server FQDN for kubectl, or null when no cluster\_domain was given. It is always computed from cluster\_domain, so check dns\_registration\_enabled before you use it. Do not use it as the registration\_address of proxmox-node-pool. |
| <a name="output_cluster_ip"></a> [cluster\_ip](#output\_cluster\_ip) | Genesis control-plane node's IP. For control\_plane\_count > 1, prefer cluster\_fqdn (when dns\_registration\_enabled) for a name that covers every control-plane node, not just genesis. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Cluster name passed to the module. |
| <a name="output_cluster_token"></a> [cluster\_token](#output\_cluster\_token) | Shared secret used to join a server to the cluster (rke2 config.yaml's token:), generated by this module. Not consumed by proxmox-node-pool — workers only ever need the agent token below. |
| <a name="output_control_plane_node_refs"></a> [control\_plane\_node\_refs](#output\_control\_plane\_node\_refs) | Map of control-plane node name -> {instance\_id, ip, provider}. |
| <a name="output_dns_registration_enabled"></a> [dns\_registration\_enabled](#output\_dns\_registration\_enabled) | Whether this control plane published cluster\_fqdn to a DNS server through dns-registration (true only when dns\_server\_address is set). Check it before you connect through cluster\_fqdn. Worker joins do not use it. |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | Provider-native node ID of the genesis control-plane VM. |
| <a name="output_node_control_ref"></a> [node\_control\_ref](#output\_node\_control\_ref) | Genesis VM ID, for control-plane verb-scripts that need a single node reference. |
| <a name="output_node_provider"></a> [node\_provider](#output\_node\_provider) | Provider identifier ('proxmox'). Control-plane scripts dispatch via qm guest exec for this provider. |
| <a name="output_pool_id"></a> [pool\_id](#output\_pool\_id) | Proxmox resource pool the control-plane VMs join, or null when they join none. |
| <a name="output_proxmox_node"></a> [proxmox\_node](#output\_proxmox\_node) | Proxmox node every control-plane VM runs on. |
| <a name="output_wildcard_dns_name"></a> [wildcard\_dns\_name](#output\_wildcard\_dns\_name) | Wildcard hostname for cluster services, or null when no cluster\_domain was given. The control plane publishes it only on an all\_in\_one cluster with dns\_server\_address set and manage\_wildcard\_dns\_record on; see wildcard\_registration\_enabled. |
| <a name="output_wildcard_registration_enabled"></a> [wildcard\_registration\_enabled](#output\_wildcard\_registration\_enabled) | Whether this control plane published wildcard\_dns\_name itself. See wildcard\_dns\_name. |
<!-- END_TF_DOCS -->
