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
| `modules/cloud-init`          | RKE2 cloud-init renderer, role-aware (`server-init` / `server-join` / `worker`). Ships a single AlmaLinux 9 template, used by every provider module. No provider resources. |
| `modules/aws-control-plane`           | AWS control-plane node(s) + shared cluster resources: join tokens, cluster/etcd security groups, registration endpoint (AlmaLinux 9). |
| `modules/aws-node-pool`     | Fixed, AZ-pinned AWS node pool (ASG + launch template) that joins an existing aws-control-plane cluster (AlmaLinux 9). |
| `modules/proxmox-control-plane`       | Proxmox control-plane node(s) + shared cluster resources: join tokens (delivered via cloud-init), cluster/etcd firewall ipsets, kube-vip VIP registration endpoint (AlmaLinux 9). |
| `modules/proxmox-node-pool` | Fixed Proxmox node pool (discrete VMs) that joins an existing proxmox-control-plane cluster (AlmaLinux 9). |
| `modules/azure-control-plane`         | Azure control-plane node(s) + shared cluster resources: join tokens via Key Vault (RBAC), cluster/etcd Application Security Groups, internal Standard LB registration endpoint (AlmaLinux 9). |
| `modules/azure-node-pool`   | Fixed, AZ-pinned Azure node pool (VM Scale Set, manual upgrade mode) that joins an existing azure-control-plane cluster (AlmaLinux 9). |

## Concepts

- **Control plane and node pools** — a cluster is a **control plane** (its control-plane
  node(s), plus cluster-wide resources: join tokens, cluster firewall, registration endpoint,
  DNS) optionally joined by one or more **node pools**. `control_plane_count` sets how many
  control-plane nodes the control plane has — 1, 3, or 5. A control plane with
  `control_plane_count = 1` and no node pools is a complete single-node cluster on its own.
- **`cluster_type`** — whether control-plane nodes run user workloads. `all_in_one` (the
  default) keeps them schedulable; every single-node cluster uses this. `dedicated_control_plane`
  taints control-plane nodes so user workloads run only on node pools.
- **Datastore** — every cluster, including single-node, runs RKE2 with embedded etcd
  (RKE2 has no SQLite option — etcd is its only supported datastore), for one consistent
  datastore and uniform snapshot behavior across topologies.
- **Join flow** — a control plane generates a server token, for control-plane nodes joining the
  same control plane, and a separate agent token, handed to node pools (via an SSM `SecureString`
  on AWS, a Key Vault secret on Azure, or cloud-init on Proxmox). A compromised worker can rejoin
  only as a worker, never as a control-plane/etcd member.

### High availability (`control_plane_count = 3` or `5`)

Each provider places one control-plane node per availability zone (at least 3 distinct AZs
required) and gives joining nodes a stable `registration_address`:

- **AWS** — an internal Network Load Balancer on port 6443; `registration_address` is its DNS
  name.
- **Azure** — an internal Standard `azurerm_lb` on port 6443; `registration_address` is its
  frontend private IP.
- **Proxmox** — no managed load-balancer primitive, so a [kube-vip](https://kube-vip.io)
  ARP-mode VIP floats across the control-plane nodes instead; `registration_address` is that VIP.
  Verify VIP failover and the live join flow against a real Proxmox cluster before relying on
  `proxmox-control-plane`/`proxmox-node-pool` in production — they're validated with `tofu test`
  against a mocked provider only.

On every provider, a control-plane node probes `registration_address` at boot before deciding
whether to join the existing quorum or initialize a new one, so replacing the first
control-plane node is a safe rejoin, not a split-brain risk.

### Durability and endpoint options (AWS)

etcd snapshots (RKE2 built-in, default-on for `control_plane_count > 1`) recover cluster state
after total control-plane loss — orthogonal to HA, which prevents the outage window in the first
place. `endpoint_mode` picks how joining nodes reach the registration endpoint: `loadbalancer`
(the NLB above, default), `dns` (cheaper Route53 multivalue-answer records with
CloudWatch-alarm-backed health checks), or `static` (bring your own address).

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
