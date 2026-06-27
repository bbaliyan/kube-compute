# node-proxmox

Provisions a single-node K3s cluster on a Proxmox Virtual Environment (PVE) VM,
consuming `node-bootstrap` for the K3s cloud-init.

## Scope

The module provisions **the VM and only what is intrinsic to it**: the VM resource,
cloud-init snippet files, and optionally the OS image download. It **never creates
network fabric** (bridges, VLANs, SDN zones) — pass an existing bridge via
`network_bridge`. It **never creates DNS records** — Proxmox has no managed DNS.

## Prerequisites

### Proxmox storage (one-time configuration)

The module uses two storage roles:

| Variable | Needs content types | Typical value |
|---|---|---|
| `iso_datastore_id` | iso, snippets | `local` |
| `disk_datastore_id` | images | `local-lvm` |

In Proxmox UI → Datacenter → Storage → select `local` → Edit → enable **Snippets** if
not already checked. (Directory storage supports all content types; LVM-thin does not
support snippets or iso.)

### Provider SSH access

The bpg/proxmox provider uses SSH to upload snippet files to Proxmox. Configure in
your provider block or via environment variables:

```hcl
provider "proxmox" {
  endpoint = "https://pve:8006"
  ssh {
    agent    = true
    username = "root"
    node {
      name    = "pve"
      address = "192.168.1.1"
    }
  }
}
```

Or: `PROXMOX_VE_SSH_USERNAME` + `PROXMOX_VE_SSH_PASSWORD` (or `PROXMOX_VE_SSH_PRIVATE_KEY`).

## Networking

No firewall rules are created. Network security is enforced at the router, the Proxmox
bridge, or the VM-level firewall — all outside this module's scope. To add VM-level
firewall rules, use `proxmox_virtual_environment_firewall_rules` in your consumer repo
referencing the `vm_id` output.

## DNS (self-service)

No DNS records are created. Set `cluster_domain` to populate `cluster_fqdn` and
`wildcard_dns_name`, then register `wildcard_dns_name → cluster_ip` in your DNS:

- **Pi-hole / AdGuard / dnsmasq**: one wildcard A record
- **Technitium / PowerDNS / RFC2136**: automate from your consumer repo via a Terraform DNS provider

## Static IP vs DHCP

Static IP (`vm_ip_address` + `vm_gateway`) is **strongly recommended**:
- `cluster_ip` output is known at plan time
- DNS entries remain stable across VM restarts

DHCP works but `cluster_ip` is only populated after the VM boots and the
qemu-guest-agent reports its IPs.

## Access

Zero inbound shell ports. Operator access is via `qm guest exec` — the qemu-guest-agent
that this module installs via vendor-data on first boot:

```bash
# Read bootstrap status (maps to kube-status control-plane verb)
qm guest exec <vm_id> -- cat /var/log/kube-node/bootstrap-status

# Retrieve kubeconfig (maps to kube-kubeconfig control-plane verb)
qm guest exec <vm_id> -- cat /etc/rancher/k3s/k3s.yaml
```

## Compute sizing

Proxmox unbundles CPU and memory: `vm_cores` + `vm_memory_mb` + `vm_disk_gb`. Set
`node_arch` explicitly (`"x86_64"` or `"arm64"`) — the operator knows their hardware;
there is no Proxmox API to derive architecture.

## OS image

Provide exactly one of:

- `os_image_url` + `os_image_file_name` — download the Ubuntu 26.04 LTS cloud image
  to `iso_datastore_id` on first apply. The file is stored in `local:import/` and
  survives `terragrunt destroy` — no re-download on subsequent applies.
- `os_image_file_id` — reference a pre-existing Proxmox file (e.g.
  `local:import/ubuntu-26.04-server-cloudimg-amd64.qcow2`) to share one image across
  clusters.

The tested OS is Ubuntu 26.04 LTS: cloud-init uses `apt-get` and
`update-ca-certificates`. Supply your own cloud-init template via `cloud_init_template`
for other distributions — no compatibility guarantee is made.

**Recommended Ubuntu 26.04 LTS URL:**
```
https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img
```

## Out of scope

- Proxmox Datacenter / cluster / node management
- Network bridge / VLAN / SDN configuration  
- VM-level firewall rules (add via `proxmox_virtual_environment_firewall_rules` in consumer repo)
- DNS records (self-service via `wildcard_dns_name` + `cluster_ip`)

## Testing

```bash
cd modules/node-proxmox
tofu init -backend=false && tofu test   # offline — mock_provider "proxmox", no credentials
```

Real `plan`/`apply` against Proxmox is run from a consumer repo.
