# kube-node

Reusable OpenTofu/Terragrunt modules to provision a single, disposable single-node
K3s cluster on the provider of choice — AWS, Proxmox, or Azure — with minimal
per-provider code.

This repo contains **no environment-specific values**. Consumers pin it by immutable
git SHA and supply their own inputs (VPC names, CA certs, registry mirrors, domains).

## Modules

| Module | Purpose |
|--------|---------|
| `modules/node-bootstrap` | Provider-agnostic cloud-init renderer (K3s bootstrap). No provider resources. |
| `modules/node-aws`       | AWS EC2 node (planned). |
| `modules/node-proxmox`   | Proxmox VM (planned). |
| `modules/node-azure`     | Azure VM (planned). |

## License

Apache-2.0. Contributions require a DCO sign-off — see CONTRIBUTING.md.
