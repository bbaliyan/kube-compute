# proxmox-cluster

A thin wrapper that composes [`proxmox-control-plane`](../proxmox-control-plane/README.md)
and [`proxmox-node-pool`](../proxmox-node-pool/README.md) into a single Terraform state.
It suits operators who want one Terragrunt directory per cluster instead of today's split
`control-plane/` + `node-pools/*` layout. It changes nothing about either composed module
internally — it only calls them from one place.

## Single state, single lock

This module puts the control plane and every worker pool in **one Terraform state with one
lock**. That buys a single `terragrunt apply` per cluster, at a real cost. You can no
longer apply `control-plane` and a node pool concurrently from separate terminals. Every
change serializes through the one state/lock. If your workflow depends on applying a
worker pool while a separate control-plane change is in flight, stay on the split layout
instead (see below). The split layout is `proxmox-control-plane` + `proxmox-node-pool`.

## Inputs of the control plane

Every input `proxmox-control-plane` accepts is available unchanged — same name,
type, default, and validation — at this module's own top level. See
[`proxmox-control-plane`'s README](../proxmox-control-plane/README.md) and its
`variables.tf` for the full list and field-by-field semantics; this module does not
re-document them.

The first control-plane node clones the platform ref (`gitops_platform_repo_url` at `gitops_platform_revision`) before RKE2 starts. It takes the Cilium and Argo CD manifests from `bootstrap/rendered/` in the clone. The template must hold git. If `gitops_platform_enabled` is false, set `gitops_platform_repo_url`, because the node still reads the Cilium manifest from it. See [`node-bootstrap`](../node-bootstrap/README.md).

After Cilium is Ready, the first server removes the Cilium file from the RKE2 manifests directory, even when GitOps is off. A later server restart then no longer applies it again.

`node_pools` is a map of worker pools keyed by pool name (e.g. `"platform"`). Each
entry's fields mirror `proxmox-node-pool`'s own `variables.tf`, minus what this module
supplies: `cluster_name`, `cluster_agent_token`,
`graceful_shutdown` and `os_auto_updates`, and the key itself as `pool_name`. An empty map (the default) creates no worker pools, the same shape as applying
`proxmox-control-plane` alone.

Every worker of a pool is named `<cluster_name>-<pool>-<n>` and carries
`kube-compute.io/node-group=<pool>`. `node_taints` keeps other pods off; pods that
belong there need a matching toleration. A pool field left null takes the cluster's own
value: `trusted_ca_pem`, `registry_mirror_url`, `ssh_authorized_keys`, `dns_servers`,
and the DNS registration settings.

`pool_id` applies to the control plane and to every pool in `node_pools`. A `node_pools` entry may set its own `pool_id` to override it. Unset, there is no Proxmox pool. Do not confuse `pool_id` (a Proxmox resource pool) with a `node_pools` key (a node group).

## Platform pool

`platform_node_group` names the pool that runs the platform stack:

- its components are pinned to that pool;
- it alone opens `ingress_ports` to `allowed_ingress_cidrs`, since Traefik runs there,
  and the control plane keeps only 6443;
- the wildcard DNS record points at its workers.

Without it, ingress and the wildcard record stay on the control plane of an
`all_in_one` cluster, and on the pools of a `dedicated_control_plane` one.

### Names in DNS

`cluster_name` is the cluster's identity: VM names, node names, firewall ipsets and DNS.
With `cluster_name = "app-red"` and `cluster_domain = "red.example.internal"`, the API name is
`api.app-red.red.example.internal`.

### DNS registration

There is no `provider "dns" {}` to wire up. DNS registration
(`dns_server_address`/`tsig_key_*`) is plain module input. The underlying
`dns-registration` module shells out to `nsupdate` rather than using a Terraform provider
(see its README for why). It just needs `nsupdate` (`bind-utils`/`dnsutils`) installed on
whatever machine runs `tofu apply`/`tofu destroy`.

## Firewall

Each VM gets a Proxmox firewall that drops inbound traffic except:
- everything from `cluster_network_cidr`;
- `ingress_ports` (TCP) from `allowed_ingress_cidrs`, on the platform pool,
  or on every pool when there is none.

The rule admits the whole subnet, so etcd (2379-2380), its plain-HTTP metrics (2381),
SSH and every other port are open to every member of `cluster_network_cidr`.

Proxmox enforces it only when **the datacenter firewall is enabled** (Datacenter →
Firewall → Options). kube-compute doesn't manage that setting. Before turning it on:
- **Host access:** it also switches on every host's own firewall. Proxmox automatically
  allows the web UI (8006) and SSH from the hosts' own subnet; allow them from anywhere
  else you administer from.
- **Proxmox API from the cluster:** if `cluster_network_cidr` isn't the hosts' own
  subnet (for example, the cluster has its own VLAN), allow 8006 to the hosts from it too.
  Otherwise the cluster can't reach the Proxmox API.
- **Other VMs:** any other VM that already has a firewall-enabled NIC starts being
  filtered too.

With it off, every port on every VM is reachable from any network that routes
to it.

**What to expect once it's on:**
- **Flat LAN:** `cluster_network_cidr` is the whole subnet, so on a flat home
  LAN every device on it is allowed in. The firewall keeps out other networks:
  other VLANs, VPNs, routed subnets. Put the cluster on its own VLAN to get
  more out of it.
- **Extra ports:** anything else exposed through a LoadBalancer Service is
  reachable from outside `cluster_network_cidr` only once its port is in
  `ingress_ports`. That covers extra Traefik ports (kube-platform's
  `traefikExtraConfig`, e.g. 5432) and other node-IPAM Services. Only TCP can
  be opened this way, and only on the pool running the Service's pods.
- **SSH:** nodes are reachable only from inside `cluster_network_cidr`. Never
  add 22 to `ingress_ports`.

## Usage: control-plane only, no worker pools

```hcl
module "cluster" {
  source = "path/to/kube-compute/modules/proxmox-cluster"

  cluster_name          = "example"
  proxmox_node           = "pve-01"
  vm_cores               = 4
  vm_memory_mb            = 8192
  vm_disk_gb              = 60
  allowed_ingress_cidrs   = ["10.0.0.0/24"]
  proxmox_template_vm_id  = 9000
}
```

This is equivalent to today's `control-plane/` unit alone — `node_pools` defaults to
`{}`, so no `proxmox-node-pool` instances are created.

## Usage: control plane plus a worker pool

```hcl
module "cluster" {
  source = "path/to/kube-compute/modules/proxmox-cluster"

  cluster_name           = "example"
  cluster_type           = "dedicated_control_plane"
  proxmox_node           = "pve-01"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 60
  allowed_ingress_cidrs  = ["10.0.0.0/24"]
  proxmox_template_vm_id = 9000
  cluster_network_cidr   = "10.0.0.0/24"
  platform_node_group    = "platform"

  node_pools = {
    platform = {
      proxmox_node           = "pve-01"
      vm_cores               = 4
      vm_memory_mb           = 16384
      vm_disk_gb             = 100
      proxmox_template_vm_id = 9000
      desired_count          = 1
      registration_address   = "10.0.0.5"
    }
    batch = {
      proxmox_node           = "pve-01"
      vm_cores               = 8
      vm_memory_mb           = 32768
      vm_disk_gb             = 100
      proxmox_template_vm_id = 9000
      desired_count          = 2
      registration_address   = "10.0.0.5"
      node_taints            = ["dedicated=batch:NoSchedule"]
    }
  }
}
```

Each key in `node_pools` becomes one `proxmox-node-pool` instance, wired to this
cluster's `cluster_name` and `cluster_agent_token` automatically.

## OS updates

`os_auto_updates`, on by default, has every node install
OS updates with `dnf-automatic` daily at 06:00 and 15 minutes after each boot. It never
reboots: kube-platform's Node OS Updates dashboard shows which nodes need one. See
[`node-bootstrap`'s README](../node-bootstrap/README.md#os-updates).

It is part of each node's first-boot cloud-init, so changing it reaches a node only
when that node is rebuilt.

## Graceful shutdown

`graceful_shutdown`, on by default at 90 seconds with the last 30 for critical pods, has
kubelet evict pods when a node's OS shuts down. A VM shut down from Proxmox or by a host
reboot then stops its workloads instead of having them killed. Raise it for workloads with
a long `terminationGracePeriodSeconds`. Keep it under what Proxmox gives a guest before
stopping it, which is 180 seconds by default when the host shuts down. Null turns it off.
See [`node-bootstrap`'s README](../node-bootstrap/README.md#graceful-shutdown). Like
`os_auto_updates`, it reaches a node only when that node is rebuilt.

## New template

A new `proxmox_template_vm_id`, for the control plane or for a pool, reaches only new VMs
and VMs that you replace. An apply does not replace the existing nodes. To roll them one at
a time, see "Rolling to a new template" in the
[`proxmox-control-plane`](../proxmox-control-plane/README.md#rolling-to-a-new-template) and
[`proxmox-node-pool`](../proxmox-node-pool/README.md#rolling-to-a-new-template) READMEs.

## Node names

`control_plane_node_name_template` names the control-plane VMs, and each `node_pools`
entry's `node_name_template` names its workers. `{number}` is required and becomes the
node's number as two digits, from `01`: `cp-{number}` gives `cp-01`, `cp-02`. The name is
the VM name, hostname, Kubernetes node name and the key in `control_plane_node_refs` and
`node_pools[*].worker_node_refs`. Unset, names stay `<cluster_name>-cp-<n>` and
`<cluster_name>-<pool>-<n>`, counting from 0. Two pools may not share a template.

Setting a template on an existing cluster changes the VM names and the keys of those
outputs. It has not been tried on a running cluster, so plan it before applying.

## User data changes

A changed input in a node's cloud-init does not touch a running VM. The node does not
apply the change. To apply it, replace the VM on purpose with `tofu apply -replace`.
See proxmox-control-plane's "A change to the user data of a running node" for the
addresses and the steps. `node_pools` workers keep running in the same way.

## Input notes

These notes hold the reasons behind some input descriptions.

- `cluster_network_cidr`: Proxmox has one flat subnet and one state owns the firewall ipset. The
  ipset cannot list each VM, because the control plane and each pool have separate states.
  The subnet CIDR stands in for "the members of this cluster".
- `dns_record_ttl`: keep it low. A caching resolver in front of the DNS server keeps the
  last answer for up to the TTL. A long TTL delays the join of nodes on a reused name.
- `extra_server_manifests`: the files are not interpreted. One example is a `HelmChartConfig` that
  changes the CoreDNS Corefile to add a forward zone for a private domain. Proxmox has no
  cloud DNS, so such a zone needs this.
- Worker join address: a pool joins through the single-target `genesis.` name and not
  through the round-robin `api.` name. A round-robin name can hang a join for 10 minutes or
  more.

## Existing standalone modules remain fully supported

`proxmox-control-plane` and `proxmox-node-pool` are unchanged and continue to work exactly
as before, applied as separate Terragrunt units with a `dependency` block carrying
`cluster_agent_token` between them. `proxmox-cluster` is an additional option for
consumers who want a single directory/state per cluster. It does not deprecate, replace,
or require migrating the split layout.

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
| <a name="input_cluster_type"></a> [cluster\_type](#input\_cluster\_type) | Cluster topology intent: 'all\_in\_one' (control-plane nodes stay schedulable) or 'dedicated\_control\_plane' (control-plane nodes are tainted so user workloads run only on separate node pools). | `string` | `"all_in_one"` | no |
| <a name="input_control_plane_count"></a> [control\_plane\_count](#input\_control\_plane\_count) | Number of control-plane nodes. Must be 1, 3, or 5 — 2 and 4 give no fault-tolerance benefit and risk split-brain. | `number` | `1` | no |
| <a name="input_control_plane_node_name_template"></a> [control\_plane\_node\_name\_template](#input\_control\_plane\_node\_name\_template) | Name for each control-plane node: its VM name, hostname and Kubernetes node name. {number} becomes the node's number as two digits (01, 02, ...) and is required. Null keeps <cluster\_name>-cp-<n>, counting from 0. Each node\_pools entry has its own node\_name\_template. | `string` | `null` | no |
| <a name="input_disk_datastore_id"></a> [disk\_datastore\_id](#input\_disk\_datastore\_id) | Proxmox storage ID for VM disks and cloud-init drives. Must support 'images' content type. | `string` | `"local-lvm"` | no |
| <a name="input_dns_record_ttl"></a> [dns\_record\_ttl](#input\_dns\_record\_ttl) | TTL in seconds for the published cluster\_fqdn record and the genesis node's self-registered record. Ignored when dns\_server\_address is null. Keep it low; see proxmox-boot-steps' dns\_self\_register\_ttl. | `number` | `30` | no |
| <a name="input_dns_server_address"></a> [dns\_server\_address](#input\_dns\_server\_address) | Hostname or IPv4 address of an RFC2136-compliant DNS server to publish cluster\_fqdn to (any server that speaks RFC2136 — not tied to a specific product). Null (default) skips DNS registration entirely; register wildcard\_dns\_name/cluster\_fqdn yourself in that case. | `string` | `null` | no |
| <a name="input_dns_server_port"></a> [dns\_server\_port](#input\_dns\_server\_port) | Port the DNS server accepts dynamic updates on. Ignored when dns\_server\_address is null. | `number` | `53` | no |
| <a name="input_dns_servers"></a> [dns\_servers](#input\_dns\_servers) | DNS nameserver addresses written into the cloud-init network-config of every VM. They also give kubelet a resolv-conf with no search domain, so a node search domain cannot match the wildcard cluster record. | `list(string)` | <pre>[<br/>  "1.1.1.1",<br/>  "8.8.8.8"<br/>]</pre> | no |
| <a name="input_dns_transport"></a> [dns\_transport](#input\_dns\_transport) | Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Ignored when dns\_server\_address is null. Defaults to 'udp'. Some DNS servers drop a TCP update mid-way. A few IPv4 addresses in one A record set fit well under the UDP message-size limit. | `string` | `"udp"` | no |
| <a name="input_extra_server_manifests"></a> [extra\_server\_manifests](#input\_extra\_server\_manifests) | RKE2 auto-deploy manifest files (filename => YAML), passed through proxmox-control-plane to node-bootstrap, which writes them to /var/lib/rancher/rke2/server/manifests/ on the genesis node only. Content is not interpreted. Empty (the default) adds none. | `map(string)` | `{}` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional Proxmox VM tags applied to every control-plane VM, and forwarded to cloud-init's platform Application (helm.valuesObject.extraTags). | `map(string)` | `{}` | no |
| <a name="input_gitops_platform_enabled"></a> [gitops\_platform\_enabled](#input\_gitops\_platform\_enabled) | Whether to bootstrap kube-platform at all. false = a bare RKE2+Cilium cluster, no Argo CD/platform Application. | `bool` | `true` | no |
| <a name="input_gitops_platform_repo_url_override"></a> [gitops\_platform\_repo\_url\_override](#input\_gitops\_platform\_repo\_url\_override) | Override for kube-platform's repo URL. Null (the default) passes through to node-bootstrap, which falls back to its own pinned default — this module is not the source of truth for the pin. | `string` | `null` | no |
| <a name="input_gitops_platform_revision_override"></a> [gitops\_platform\_revision\_override](#input\_gitops\_platform\_revision\_override) | Override for the branch/tag/SHA the platform Application tracks. Null (the default) passes through to node-bootstrap's own pinned default. | `string` | `null` | no |
| <a name="input_gitops_workloads_path"></a> [gitops\_workloads\_path](#input\_gitops\_workloads\_path) | Path within the workloads repo Argo CD applies. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"."` | no |
| <a name="input_gitops_workloads_repo_url"></a> [gitops\_workloads\_repo\_url](#input\_gitops\_workloads\_repo\_url) | Optional user-defined workloads Application source repo, independent of the platform Application (no shared ordering). Null (the default) = no workloads Application. | `string` | `null` | no |
| <a name="input_gitops_workloads_revision"></a> [gitops\_workloads\_revision](#input\_gitops\_workloads\_revision) | Branch/tag/SHA the workloads Application tracks. Only meaningful when gitops\_workloads\_repo\_url is set. | `string` | `"main"` | no |
| <a name="input_graceful_shutdown"></a> [graceful\_shutdown](#input\_graceful\_shutdown) | How long kubelet delays an OS shutdown to evict pods. critical\_seconds is the part reserved for critical pods and must leave room for an ordinary pod's terminationGracePeriodSeconds. Null disables it. Keep the total well under 2 minutes. | <pre>object({<br/>    seconds          = optional(number, 90)<br/>    critical_seconds = optional(number, 30)<br/>  })</pre> | `{}` | no |
| <a name="input_ingress_ports"></a> [ingress\_ports](#input\_ingress\_ports) | TCP ports opened from allowed\_ingress\_cidrs on every control-plane VM: 443/80 Traefik, 6443 Kubernetes API. Never add 22 (SSH). | `list(number)` | <pre>[<br/>  80,<br/>  443,<br/>  6443<br/>]</pre> | no |
| <a name="input_iso_datastore_id"></a> [iso\_datastore\_id](#input\_iso\_datastore\_id) | Proxmox storage ID for the OS image download and cloud-init snippet files. Must support 'iso', 'snippets', and 'import' content types. | `string` | `"local"` | no |
| <a name="input_network_bridge"></a> [network\_bridge](#input\_network\_bridge) | Proxmox Linux bridge every control-plane VM's NIC attaches to. The module never creates bridges — pass an existing one. | `string` | `"vmbr0"` | no |
| <a name="input_node_pools"></a> [node\_pools](#input\_node\_pools) | Static worker pools joining this cluster, keyed by pool name (e.g. 'platform'), each created through proxmox-node-pool with the cluster's identity and join token. Workers are named <cluster\_name>-<pool>-<n>. A null field takes the cluster's value. Empty (the default) creates none. | <pre>map(object({<br/>    trusted_ca_pem         = optional(string)<br/>    registry_mirror_url    = optional(string)<br/>    proxmox_node           = string<br/>    disk_datastore_id      = optional(string, "local-lvm")<br/>    iso_datastore_id       = optional(string, "local")<br/>    network_bridge         = optional(string, "vmbr0")<br/>    vm_cores               = number<br/>    vm_memory_mb           = number<br/>    vm_disk_gb             = number<br/>    vm_cpu_type            = optional(string, "x86-64-v2-AES")<br/>    pool_id                = optional(string)<br/>    proxmox_template_vm_id = optional(number)<br/>    ssh_authorized_keys    = optional(list(string))<br/>    dns_servers            = optional(list(string))<br/>    desired_count          = optional(number, 2)<br/>    registration_address   = optional(string)<br/>    extra_node_labels      = optional(map(string), {})<br/>    node_taints            = optional(list(string), [])<br/>    cluster_domain         = optional(string)<br/>    dns_server_address     = optional(string)<br/>    dns_server_port        = optional(number)<br/>    dns_transport          = optional(string)<br/>    dns_record_ttl         = optional(number)<br/>    tsig_key_name          = optional(string)<br/>    tsig_key_algorithm     = optional(string)<br/>    tsig_key_secret        = optional(string)<br/>    node_name_template     = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_os_auto_updates"></a> [os\_auto\_updates](#input\_os\_auto\_updates) | Install OS updates with dnf-automatic on every node, daily and 15 minutes after each boot, without rebooting. RKE2 packages are excluded, because system-upgrade-controller upgrades them. needs-restarting (yum-utils) reports a due reboot. False leaves packages as baked. | `bool` | `true` | no |
| <a name="input_platform_extra_helm_parameters"></a> [platform\_extra\_helm\_parameters](#input\_platform\_extra\_helm\_parameters) | Additional Helm parameters forwarded verbatim to the kube-platform bootstrap Application. | `map(string)` | `{}` | no |
| <a name="input_platform_helm_values_object"></a> [platform\_helm\_values\_object](#input\_platform\_helm\_values\_object) | Arbitrary object forwarded to the platform Application as helm.valuesObject. | `any` | `null` | no |
| <a name="input_platform_node_group"></a> [platform\_node\_group](#input\_platform\_node\_group) | node\_pools key of the pool running the platform stack, ingress included. Its node-group label pins the platform pods, it alone opens ingress\_ports, and the wildcard DNS record points at its workers. Null keeps all of that on the control plane, or on every pool of a dedicated\_control\_plane cluster. | `string` | `null` | no |
| <a name="input_pool_id"></a> [pool\_id](#input\_pool\_id) | Proxmox resource pool the control-plane VMs and every node\_pools worker join, unless a node\_pools entry sets its own pool\_id. Null (default) puts them in no pool. A token scoped to one pool can only create VMs there. | `string` | `null` | no |
| <a name="input_proxmox_node"></a> [proxmox\_node](#input\_proxmox\_node) | Proxmox node name every control-plane VM is placed on (the hostname shown in the Proxmox UI under Datacenter). Cross-host spread for HA is a future enhancement — all control-plane VMs land on this one Proxmox node today. | `string` | n/a | yes |
| <a name="input_proxmox_template_vm_id"></a> [proxmox\_template\_vm\_id](#input\_proxmox\_template\_vm\_id) | VM ID of the kube-images Proxmox template to full-clone every control-plane node from. A new value reaches only new or replaced VMs. To roll nodes one at a time, see 'Rolling to a new template' in the proxmox-control-plane and proxmox-node-pool READMEs. | `number` | n/a | yes |
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
| <a name="output_cluster_agent_token"></a> [cluster\_agent\_token](#output\_cluster\_agent\_token) | Shared secret accepted only from agents. Also wired internally into every module.node\_pools entry — exposed here for consumers that need it directly (e.g. a hand-rolled worker outside node\_pools). |
| <a name="output_cluster_fqdn"></a> [cluster\_fqdn](#output\_cluster\_fqdn) | API server / kubeconfig FQDN, or null when no cluster\_domain was given. |
| <a name="output_cluster_ip"></a> [cluster\_ip](#output\_cluster\_ip) | Genesis control-plane node's IP. For control\_plane\_count > 1, prefer cluster\_fqdn (when dns\_registration\_enabled) for a name that covers every control-plane node, not just genesis. |
| <a name="output_cluster_name"></a> [cluster\_name](#output\_cluster\_name) | Cluster name passed to the module. |
| <a name="output_cluster_token"></a> [cluster\_token](#output\_cluster\_token) | Shared secret used to join a server to the cluster. |
| <a name="output_control_plane_node_refs"></a> [control\_plane\_node\_refs](#output\_control\_plane\_node\_refs) | Map of control-plane node name -> {instance\_id, ip, provider}. |
| <a name="output_dns_registration_enabled"></a> [dns\_registration\_enabled](#output\_dns\_registration\_enabled) | Whether the control plane actually published cluster\_fqdn to a DNS server. |
| <a name="output_instance_id"></a> [instance\_id](#output\_instance\_id) | Provider-native node ID of the genesis control-plane VM. |
| <a name="output_node_control_ref"></a> [node\_control\_ref](#output\_node\_control\_ref) | Genesis VM ID, for control-plane verb-scripts that need a single node reference. |
| <a name="output_node_pools"></a> [node\_pools](#output\_node\_pools) | Map of pool name (matching var.node\_pools' own keys) -> {node\_provider, worker\_node\_refs, wildcard\_dns\_registration\_enabled, pool\_id}, one entry per configured pool. Empty map when var.node\_pools is empty. |
| <a name="output_node_provider"></a> [node\_provider](#output\_node\_provider) | Provider identifier ('proxmox'). |
| <a name="output_pool_id"></a> [pool\_id](#output\_pool\_id) | Proxmox resource pool the control-plane VMs join, or null when they join none. |
| <a name="output_proxmox_node"></a> [proxmox\_node](#output\_proxmox\_node) | Proxmox node the control-plane VM(s) run on. |
| <a name="output_wildcard_dns_name"></a> [wildcard\_dns\_name](#output\_wildcard\_dns\_name) | Wildcard hostname for cluster services, or null when no cluster\_domain was given. |
| <a name="output_wildcard_registration_enabled"></a> [wildcard\_registration\_enabled](#output\_wildcard\_registration\_enabled) | Whether the control plane itself published wildcard\_dns\_name to DNS. |
<!-- END_TF_DOCS -->
