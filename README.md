# kube-compute

Reusable OpenTofu/Terragrunt modules for the compute layer of an RKE2 cluster —
control-plane and worker nodes, the load balancer/VIP and DNS needed to reach them,
and node-scoped firewalling — on the provider of choice (AWS, Proxmox, or Azure) with
minimal per-provider code. Not a single node: a cluster is a **control plane**
(control-plane node(s) plus cluster-wide resources) optionally joined by one or more
**node pools**; `control_plane_count = 1` with no node pools is a complete
single-node cluster.

This is the compute half of the stack — what runs *on top* (GitOps, platform services)
is [`kube-platform`](https://github.com/bbaliyan/kube-platform).

This repo contains **no environment-specific values**. Consumers supply their own inputs
(VPC names, CA certs, registry mirrors, domains) and take each provider's cluster module
from the OpenTofu Registry, from its mirror repo, or from here by git SHA -- see
[Releases](#releases).

## Modules

Each provider has one cluster module that composes the others. Use it when you want one state for a whole cluster. Use the provider modules directly when you want a separate state for the control plane and each pool.

| Layer | Module | Purpose |
|-------|--------|---------|
| Cluster | `modules/aws-cluster` | One state for a whole AWS cluster: the control plane, named workers and autoscaled workers. It is the root of the AWS registry release. |
| Cluster | `modules/proxmox-cluster` | One state for a whole Proxmox cluster: the control plane and the worker pools. It is the root of the Proxmox registry release. |
| Provider | `modules/aws-control-plane` | The control-plane node(s) and the cluster-wide resources: join tokens, security groups, IAM, the API load balancer and DNS records. With `control_plane_count = 1` it is a complete single-node cluster. |
| Provider | `modules/aws-static-node` | A group of named, fixed worker instances in one role, such as `platform` or `build`. `node_count` sets how many. |
| Provider | `modules/aws-node-pool` | One role of workers that cluster-autoscaler scales from zero, as EC2 Auto Scaling groups. |
| Provider | `modules/proxmox-control-plane` | The control-plane VM(s) on Proxmox, with the join tokens and the cluster firewall group. |
| Provider | `modules/proxmox-node-pool` | A pool of fixed worker VMs on Proxmox, named `<cluster>-<pool>-<n>`. |
| Shared | `modules/node-bootstrap` | Renders the boot configuration (`#cloud-config`) for one node, for a role the caller has already chosen: `server-init`, `server-join` or `worker`. It produces a string and creates no resource. It expects the RKE2 binaries to be baked into the node image from [`kube-images`](https://github.com/bbaliyan/kube-images). |
| Shared | `modules/proxmox-vendor-data` | Renders the cloud-init vendor data that every Proxmox VM shares: a persistent journal, the SSH keys, the guest agent and the serial console. It produces a string and creates no resource. |
| Shared | `modules/dns-registration` | Publishes an A record set to an RFC2136 DNS server with a TSIG-signed dynamic update. Proxmox uses it because its DNS server is external. AWS creates its Route 53 records with `aws_route53_record`, because Route 53 does not accept RFC2136 updates. |
| Placeholder | `modules/azure-control-plane`, `modules/azure-node-pool` | Not implemented. Azure is a target provider, and each directory holds only a README. |

## Concepts

- **Control plane and node pools** — a cluster is a **control plane** (its control-plane
  node(s), plus cluster-wide resources: join tokens, cluster firewall, registration endpoint,
  DNS) optionally joined by one or more **node pools**. `control_plane_count` sets how many
  control-plane nodes it has — 1, 3, or 5. `control_plane_count = 1` with no node pools is a
  complete single-node cluster on its own.
- **`cluster_type`** — whether control-plane nodes run user workloads. `all_in_one` (default)
  keeps them schedulable; every single-node cluster uses this. `dedicated_control_plane` taints
  them so user workloads run only on node pools.
- **Datastore** — every cluster, including single-node, runs RKE2 with embedded etcd (RKE2's
  only supported datastore — no SQLite option), for one consistent datastore across topologies.
- **Join flow** — a control plane generates a server token for control-plane nodes joining the
  same control plane, and a separate agent token for node pools (SSM `SecureString` on AWS,
  cloud-init on Proxmox, Key Vault once Azure exists). A compromised worker can rejoin only as a
  worker, never as a control-plane/etcd member.

### High availability (`control_plane_count = 3` or `5`)

Joining nodes use a stable `registration_address`. The providers differ in where they place the nodes:

- **AWS** places one control-plane node per availability zone. It needs at least 3 distinct zones.
- **Proxmox** places every control-plane VM on the one `proxmox_node`. Losing that host stops the whole control plane.

The address comes from the provider:

- **AWS** — an internal Network Load Balancer on port 6443; `registration_address` is its DNS
  name.
- **Azure** — not implemented (see `modules/azure-control-plane`'s README); an internal Standard
  `azurerm_lb` on port 6443 is the intended design.
- **Proxmox** — no managed load-balancer primitive, so joining control-plane nodes dial the
  `genesis.<cluster>.<cluster_domain>` DNS name (`registration_address`). DNS is required for
  more than one control-plane node, so set `cluster_domain` and `dns_server_address`.
  `cluster_fqdn` is the stable multi-node address for clients outside the join flow. See
  `modules/dns-registration`'s README. `tofu test` against a mocked provider and a rolling template
  update of a three-node cluster on DHCP have validated the join flow and the DNS registration.

On a multi-node cluster, the first control-plane node probes the live cluster at boot. If the
cluster answers, the node joins it. If not, the node initializes a new cluster. On AWS it probes
`registration_address`. On Proxmox it probes the static IP of every other control-plane node, in
order (`rejoin_probe_addresses`), because its own join address points back at itself. It joins
through the first one that answers. A Proxmox cluster whose control-plane nodes use DHCP has no
addresses to list. There the first node resolves the cluster name `api.<cluster>.<cluster_domain>`
and probes each IP that remains after it skips its own. It repeats the probe for about 60 seconds.

If no probed address answers, the node initializes a new cluster. So do not replace the first
node in the same apply as every other control-plane node. Any HTTPS service that answers at a
peer IP can start a join attempt, so each peer IP must belong to a control-plane node only.

On Proxmox a new `proxmox_template_vm_id` reaches only new VMs and VMs that you replace, so one
apply never rebuilds every node. Replace the nodes one at a time: the additional control-plane
nodes first, the first node last and in its own apply, then the workers. The
`proxmox-control-plane` and `proxmox-node-pool` READMEs give the steps. The AWS control plane
also keeps its nodes on a new AMI.

### Endpoint options (AWS)

`endpoint_mode` picks how joining nodes reach the registration endpoint: `loadbalancer`
(the NLB above, default), `dns` (cheaper Route53 multivalue-answer records with
CloudWatch-alarm-backed health checks), or `static` (bring your own address).

## Releases

Each provider's cluster module is published on its own, from a read-only mirror repo:

| Provider | Registry address | Mirror repo | Built from |
|---|---|---|---|
| AWS | `bbaliyan/kube-compute/aws` | [terraform-aws-kube-compute](https://github.com/bbaliyan/terraform-aws-kube-compute) | `modules/aws-cluster` |
| Proxmox | `bbaliyan/kube-compute/proxmox` | [terraform-proxmox-kube-compute](https://github.com/bbaliyan/terraform-proxmox-kube-compute) | `modules/proxmox-cluster` |

A mirror's root module is the provider's `<provider>-cluster` module. Under `modules/` it
carries every module that one uses, found by following its `source = "../..."` lines, with
the provider prefix dropped (`aws-node-pool` becomes `modules/node-pool`).
`scripts/release-split.sh` builds the tree; `release-split.sh --paths <provider>` lists
what it is built from. Every module's `variables.tf` and `outputs.tf` are byte-identical
to the ones here, so a consumer can switch between the three sources without changing its
inputs.

**To release, push a `vX.Y.Z` tag.** The `Release split` workflow builds each provider's
tree, validates and tests it, and compares it with what the mirror already has. Where it
differs, the workflow commits it to the mirror under the same tag and creates a GitHub
release. The registry picks up the new tag by itself. A tag that changes only AWS modules
releases only AWS, so a mirror's versions can skip numbers. To re-run a tag, or build one
without pushing anything, run the workflow by hand from the Actions tab (`dry_run` is on
by default).

CI builds and tests both mirrors on every pull request, so a change that would break a
release fails there.

**To add a provider**, create `terraform-<provider>-kube-compute` as an empty public repo,
add it to the `SPLIT_REPO_PAT` token's repositories, and add the provider to the matrix in
both `release-split.yml` and `ci.yml`. Once the first release has been tagged there, submit
it to the OpenTofu Registry by opening a "Submit new Module" issue on
[opentofu/registry](https://github.com/opentofu/registry/issues/new/choose) that names the
repo.

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
