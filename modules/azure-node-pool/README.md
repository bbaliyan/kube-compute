# azure-node-pool

**Placeholder — not implemented.** Azure is one of this project's three target
providers (AWS, Proxmox, Azure), but there is currently no working
`azure-node-pool` module. This directory intentionally contains no `.tf`
files.

## Intended design

Follow the pattern of `aws-node-pool` and `proxmox-node-pool`:

- Boot from a pre-baked `kube-images` template that holds the RKE2 binaries, the
  prerequisites and the Cilium manifest.
- Attach a `#cloud-config` payload rendered by `modules/node-bootstrap` to configure and join RKE2.
  Use no execution engine and no inbound connection to the node.
- Fetch the agent join token from Azure Key Vault with a Managed Identity. This is the
  Azure equivalent of the AWS SSM `SecureString` fetch.

Do not start this work until AWS and Proxmox are validated against real infrastructure.
