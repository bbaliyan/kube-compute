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

This repo contains **no environment-specific values**. Consumers pin it by immutable
git SHA and supply their own inputs (VPC names, CA certs, registry mirrors, domains).

## Modules

| Module | Purpose |
|--------|---------|
| `modules/node-bootstrap`      | Renders a single node's RKE2 bootstrap as a lean cloud-init `#cloud-config` payload — hostname, secrets, join logic, RKE2/CNI/GitOps config — role-aware (`server-init` / `server-join` / `worker`). No execution, no provider resources, no Ansible: only produces a string. Assumes RKE2 binaries/prerequisites are already baked into the node image ([`kube-image`](https://github.com/bbaliyan/kube-image)) — a stock cloud image won't have a working RKE2 install. **AWS and Proxmox both consume this module today**, booting from a kube-image-baked image with no live connection to the node. Azure has no caller yet — see `modules/node-bootstrap/README.md`. |
| `modules/aws-control-plane`           | AWS control-plane node(s) + shared cluster resources: join tokens, cluster security group, agent-token SSM parameter, registration endpoint (AlmaLinux 10). Boots from a pre-baked [`kube-image`](https://github.com/bbaliyan/kube-image) AMI (`os_image_ami_id`) — no live Ansible connection, no `aws-cluster-facts` dependency. |
| `modules/aws-node-pool`     | Fixed-size AWS ASG, AZ-pinned, that joins an existing aws-control-plane cluster (AlmaLinux 10). |
| `modules/proxmox-control-plane`       | Proxmox control-plane node(s) + shared cluster resources: join tokens (via cloud-init), cluster/etcd firewall ipsets, genesis-direct registration endpoint, optional RFC2136 DNS registration (AlmaLinux 10). Boots from a pre-baked [`kube-image`](https://github.com/bbaliyan/kube-image) template (`proxmox_template_vm_id`) — see its README's "Booting from a kube-image template" section. |
| `modules/proxmox-node-pool` | Fixed Proxmox node pool (discrete VMs) joining an existing proxmox-control-plane cluster (AlmaLinux 10). Same kube-image template requirement as `proxmox-control-plane`. |
| `modules/dns-registration` | Publishes an A record set to an RFC2136-compliant DNS server via TSIG-authenticated dynamic update. Used by `proxmox-control-plane` for its HA registration endpoint. |
| `modules/azure-control-plane`         | **Placeholder — not implemented.** Azure is a target provider but has no working module; the prior live-Ansible implementation was removed, unvalidated against real Azure (no Azure connectivity in the dev environment). See the module's README for intended direction. |
| `modules/azure-node-pool`   | **Placeholder — not implemented.** Same reason as `azure-control-plane`. |

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

Each provider places one control-plane node per availability zone (at least 3 distinct AZs
required) and gives joining nodes a stable `registration_address`:

- **AWS** — an internal Network Load Balancer on port 6443; `registration_address` is its DNS
  name.
- **Azure** — not implemented (see `modules/azure-control-plane`'s README); an internal Standard
  `azurerm_lb` on port 6443 is the intended design.
- **Proxmox** — no managed load-balancer primitive, so joining control-plane nodes dial genesis's
  own IP directly (`registration_address`); `cluster_fqdn` (optionally published via
  `dns-registration`) is the stable multi-node address for clients outside the join flow — see
  `modules/dns-registration`'s README. Verify the live join flow and DNS registration against a
  real Proxmox cluster before production use — validated so far only with `tofu test` against a
  mocked provider.

On every provider, a control-plane node probes `registration_address` at boot before deciding
whether to join the existing quorum or initialize a new one, so replacing the first
control-plane node is a safe rejoin, not a split-brain risk.

### Endpoint options (AWS)

`endpoint_mode` picks how joining nodes reach the registration endpoint: `loadbalancer`
(the NLB above, default), `dns` (cheaper Route53 multivalue-answer records with
CloudWatch-alarm-backed health checks), or `static` (bring your own address).

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
