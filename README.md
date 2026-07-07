# kube-node

Reusable OpenTofu/Terragrunt modules to provision a single, disposable single-node
K3s cluster on the provider of choice — AWS, Proxmox, or Azure — with minimal
per-provider code.

This repo contains **no environment-specific values**. Consumers pin it by immutable
git SHA and supply their own inputs (VPC names, CA certs, registry mirrors, domains).

## Modules

| Module | Purpose |
|--------|---------|
| `modules/node-bootstrap`  | K3s cloud-init renderer, role-aware (`server-init` / `server-join` / `worker`). Ships two OS templates: AL2023 (used by spine-aws and worker-pool-aws) and Ubuntu 26.04 LTS (used by node-proxmox and node-azure). No provider resources. |
| `modules/spine-aws`       | AWS control-plane node(s) + shared cluster resources: join tokens, cluster/etcd security groups, registration endpoint (Amazon Linux 2023). |
| `modules/worker-pool-aws` | Fixed, AZ-pinned AWS worker pool (ASG + launch template) that joins an existing spine-aws cluster (Amazon Linux 2023). |
| `modules/spine-proxmox`       | Proxmox control-plane node(s) + shared cluster resources: join tokens (delivered via cloud-init), cluster/etcd firewall ipsets, kube-vip VIP registration endpoint (Ubuntu 26.04 LTS). |
| `modules/worker-pool-proxmox` | Fixed Proxmox worker pool (discrete VMs) that joins an existing spine-proxmox cluster (Ubuntu 26.04 LTS). |
| `modules/node-azure`      | Azure VM (Ubuntu 26.04 LTS). |

## Concepts

- **Spine** — the stable core of a cluster: its control-plane node(s) plus the cluster-wide
  resources (join tokens, cluster firewall, registration endpoint, DNS). A spine with
  `control_plane_count = 1` *is* a complete single-node cluster; larger topologies add worker
  pools alongside it. "Spine" is a term coined for this project, not a standard Kubernetes one.
- **`cluster_type`** — `all_in_one` (control-plane nodes stay schedulable; the default, and what
  every single-node cluster uses) or `dedicated_control_plane` (control-plane nodes are tainted
  so user workloads run only on separate worker pools).
- **Datastore** — every cluster, including single-node, runs K3s with embedded etcd
  (`--cluster-init`) rather than the SQLite default, for one consistent datastore and uniform
  snapshot behavior across topologies.
- **Join flow** — a spine pre-generates a server token and a separate agent token; only the agent
  token is given to worker pools (via an SSM `SecureString` on AWS), so a compromised worker cannot
  rejoin as a control-plane/etcd member. On AWS, cluster members reach each other over a
  self-referencing security group, and etcd (2379-2380) is further restricted to
  control-plane-only members by exact instance membership. On Proxmox this extra etcd restriction
  has no additional effect: the cluster-wide ipset already ACCEPTs all traffic from the whole
  subnet CIDR (see below), so a narrower etcd-only rule is a strict subset of what's already
  allowed from any other host on that subnet — it only matters against traffic from outside the
  subnet, which the default-DROP policy blocks regardless. Operators who want etcd traffic
  genuinely isolated from other subnet occupants on Proxmox should put the cluster on its own
  dedicated subnet/VLAN.
- **HA control plane** — `control_plane_count = 3` or `5` places one control-plane node per
  availability zone (at least 3 distinct AZs required) behind an internal Network Load Balancer
  on port 6443. `registration_address` becomes the NLB's DNS name. A control-plane node's
  bootstrap probes that address at boot before deciding whether to join the existing quorum or
  initialize a new one — so replacing the first control-plane node is a safe rejoin, not a
  split-brain risk.
- **Proxmox HA registration endpoint** — Proxmox has no load-balancer primitive, so `control_plane_count = 3` or `5`
  runs a [kube-vip](https://kube-vip.io) ARP-mode VIP across the control-plane nodes instead of a cloud LB.
  `registration_address` becomes that VIP. The cluster-wide firewall is a Proxmox ipset scoped to the cluster's
  L2 subnet CIDR (not exact per-VM IPs like AWS's self-referencing security group) — `bpg/proxmox`'s ipset
  resource is owned by one Terraform state, and worker pools are deliberately separate state, so exact
  cross-state membership isn't possible; see `modules/spine-proxmox`'s `cluster_network_cidr` variable.
  `spine-proxmox` and `worker-pool-proxmox` are validated with `tofu test` against a mocked
  provider only; operators should verify VIP failover and the live join flow against a real
  Proxmox cluster before relying on either module in production.
- **Durability and endpoint options** — etcd snapshots (K3s built-in, default-on for
  `control_plane_count > 1`) recover cluster state after total control-plane loss; they are
  orthogonal to availability (HA), which prevents the outage window in the first place.
  `endpoint_mode` picks how joining nodes reach the registration endpoint: `loadbalancer` (an
  internal NLB, the default), `dns` (cheaper Route53 multivalue-answer records with
  CloudWatch-alarm-backed health checks), or `static` (bring your own address).

## Example: consumer region hierarchy

`examples/consumer/live/aws/` shows the Terragrunt layout a consumer repo uses to
organize multiple clusters across regions/AZs — see its README for the full
walkthrough.

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
