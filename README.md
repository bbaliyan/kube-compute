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
| `modules/node-proxmox`    | Proxmox VM (Ubuntu 26.04 LTS). |
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
  rejoin as a control-plane/etcd member. Cluster members reach each other over a self-referencing
  security group; etcd (2379-2380) is further restricted to control-plane-only members.

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
