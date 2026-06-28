# kube-node

Reusable OpenTofu/Terragrunt modules to provision a single, disposable single-node
K3s cluster on the provider of choice — AWS, Proxmox, or Azure — with minimal
per-provider code.

This repo contains **no environment-specific values**. Consumers pin it by immutable
git SHA and supply their own inputs (VPC names, CA certs, registry mirrors, domains).

## Modules

| Module | Purpose |
|--------|---------|
| `modules/node-bootstrap` | K3s cloud-init renderer. Ships two OS templates: AL2023 (used by node-aws) and Ubuntu 26.04 LTS (used by node-proxmox and node-azure). No provider resources. |
| `modules/node-aws`       | AWS EC2 node (Amazon Linux 2023). |
| `modules/node-proxmox`   | Proxmox VM (Ubuntu 26.04 LTS). |
| `modules/node-azure`     | Azure VM (Ubuntu 26.04 LTS). |

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
