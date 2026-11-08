# azure-control-plane

**Placeholder — not implemented.** Azure is one of this project's three target
providers (AWS, Proxmox, Azure), but there is currently no working
`azure-control-plane` module. This directory intentionally contains no `.tf`
files.

## Intended design

Follow the pattern of `aws-control-plane` and `proxmox-control-plane`:

- Boot from a pre-baked `kube-images` template that holds the RKE2 binaries, the
  prerequisites and the Cilium manifest.
- Attach a `#cloud-config` payload rendered by `modules/node-bootstrap` to configure and start RKE2.
  Use no execution engine and no inbound connection to the node.
- Deliver the agent join token with Azure Key Vault and a Managed Identity. This is the
  Azure equivalent of the AWS SSM `SecureString`.
- Register the control plane behind an internal Standard `azurerm_lb` on port 6443.

Do not start this work until AWS and Proxmox are validated against real infrastructure.
