# kube-node

Reusable OpenTofu/Terragrunt modules to provision a disposable K3s cluster on the
provider of choice — AWS, Proxmox, or Azure — with minimal per-provider code. A
cluster is a **spine** (control-plane node(s) plus cluster-wide resources) optionally
joined by one or more **worker pools**; `control_plane_count = 1` with no worker pools
is a complete single-node cluster.

This repo contains **no environment-specific values**. Consumers pin it by immutable
git SHA and supply their own inputs (VPC names, CA certs, registry mirrors, domains).

## Modules

| Module | Purpose |
|--------|---------|
| `modules/node-bootstrap`      | K3s cloud-init renderer, role-aware (`server-init` / `server-join` / `worker`). Ships two OS templates: AL2023 (used by spine-aws and worker-pool-aws) and Ubuntu 26.04 LTS (used by the Proxmox and Azure modules). No provider resources. |
| `modules/spine-aws`           | AWS control-plane node(s) + shared cluster resources: join tokens, cluster/etcd security groups, registration endpoint (Amazon Linux 2023). |
| `modules/worker-pool-aws`     | Fixed, AZ-pinned AWS worker pool (ASG + launch template) that joins an existing spine-aws cluster (Amazon Linux 2023). |
| `modules/spine-proxmox`       | Proxmox control-plane node(s) + shared cluster resources: join tokens (delivered via cloud-init), cluster/etcd firewall ipsets, kube-vip VIP registration endpoint (Ubuntu 26.04 LTS). |
| `modules/worker-pool-proxmox` | Fixed Proxmox worker pool (discrete VMs) that joins an existing spine-proxmox cluster (Ubuntu 26.04 LTS). |
| `modules/spine-azure`         | Azure control-plane node(s) + shared cluster resources: join tokens via Key Vault (RBAC), cluster/etcd Application Security Groups, internal Standard LB registration endpoint (Ubuntu 26.04 LTS). |
| `modules/worker-pool-azure`   | Fixed, AZ-pinned Azure worker pool (VM Scale Set, manual upgrade mode) that joins an existing spine-azure cluster (Ubuntu 26.04 LTS). |

## Concepts

- **Spine and worker pools** — a cluster is a **spine** (its control-plane node(s), plus
  cluster-wide resources: join tokens, cluster firewall, registration endpoint, DNS) optionally
  joined by one or more **worker pools**. `control_plane_count` sets how many control-plane nodes
  the spine has — 1, 3, or 5. A spine with `control_plane_count = 1` and no worker pools is a
  complete single-node cluster on its own. "Spine" is a term coined for this project, not a
  standard Kubernetes one.
- **`cluster_type`** — whether control-plane nodes run user workloads. `all_in_one` (the
  default) keeps them schedulable; every single-node cluster uses this. `dedicated_control_plane`
  taints control-plane nodes so user workloads run only on worker pools.
- **Datastore** — every cluster, including single-node, runs K3s with embedded etcd
  (`--cluster-init`) rather than the SQLite default, for one consistent datastore and uniform
  snapshot behavior across topologies.
- **Join flow** — a spine generates a server token, for control-plane nodes joining the same
  spine, and a separate agent token, handed to worker pools (via an SSM `SecureString` on AWS, a
  Key Vault secret on Azure, or cloud-init on Proxmox). A compromised worker can rejoin only as a
  worker, never as a control-plane/etcd member.

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
  `spine-proxmox`/`worker-pool-proxmox` in production — they're validated with `tofu test`
  against a mocked provider only.

On every provider, a control-plane node probes `registration_address` at boot before deciding
whether to join the existing quorum or initialize a new one, so replacing the first
control-plane node is a safe rejoin, not a split-brain risk.

### Durability and endpoint options (AWS)

etcd snapshots (K3s built-in, default-on for `control_plane_count > 1`) recover cluster state
after total control-plane loss — orthogonal to HA, which prevents the outage window in the first
place. `endpoint_mode` picks how joining nodes reach the registration endpoint: `loadbalancer`
(the NLB above, default), `dns` (cheaper Route53 multivalue-answer records with
CloudWatch-alarm-backed health checks), or `static` (bring your own address).

## Consumer examples

Real Terragrunt usage examples (region hierarchy, HA + worker pools) live in the
separate [`kube-examples`](https://github.com/bbaliyan/kube-examples) repo, not here —
this repo stays code-only.

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
