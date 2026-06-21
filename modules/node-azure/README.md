# node-azure

Provisions a single-node K3s cluster on an Azure Linux VM, consuming `node-bootstrap`
for the K3s cloud-init.

## Scope

The module provisions **the VM and only what is intrinsic to it**: the VM, its NIC, a
node-scoped NSG, and optionally a DNS wildcard record. It **never creates network fabric**
(VNet, subnet, route tables, NAT) — pass an existing VNet and subnet via `vnet_name` +
`subnet_name`. Azure has no default VNet, so these are required.

## Prerequisites

### Azure provider configuration (in your consumer repo)

```hcl
provider "azurerm" {
  features {}
  subscription_id = "00000000-0000-0000-0000-000000000000"
}
```

The `features {}` block is required by `hashicorp/azurerm`. Authenticate via environment
variables (`ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`) or `az login`.

### Required resources (pre-existing, not created by this module)

- **Resource group** — create with `az group create`
- **VNet + subnet** — create in your consumer repo or manually

## Networking

A node-scoped NSG is created and attached to the VM's NIC. Port 22 (SSH) is explicitly
denied at priority 50 regardless of `ingress_ports`. `allowed_ingress_cidrs` controls which
networks reach the cluster ports. The module does not create VNet, subnet, or route tables.

## DNS (self-service)

No DNS records are created by default. Set `cluster_domain` to populate `cluster_fqdn`
and `wildcard_dns_name`. To have the module create a wildcard A record automatically,
also set `dns_zone_resource_group` pointing to the resource group containing an Azure DNS
zone whose name matches `cluster_domain`:

- **Azure DNS auto-record**: set both `cluster_domain` + `dns_zone_resource_group`
- **External DNS**: use the `wildcard_dns_name` + `cluster_ip` outputs with any DNS provider

## Static IP vs dynamic

Static IP (`vm_private_ip`) is **strongly recommended**:
- `cluster_ip` output is known at plan time
- DNS entries remain stable across VM restarts

Without it, `cluster_ip` is only populated after the VM is created and Azure assigns an IP.

## Access

Zero inbound shell ports. SSH is blocked at the NSG. Operator access is via Azure
run-command — no inbound port required:

```bash
# Read bootstrap status
az vm run-command invoke \
  --ids $(tofu output -raw bootstrap_status_ref) \
  --command-id RunShellScript \
  --scripts 'cat /var/log/kube-node/bootstrap-status'

# Retrieve kubeconfig
az vm run-command invoke \
  --ids $(tofu output -raw bootstrap_status_ref) \
  --command-id RunShellScript \
  --scripts 'cat /etc/rancher/k3s/k3s.yaml'
```

## OS image

`os_image_urn` defaults to Azure Linux 4 gen2 (`MicrosoftCBLMariner:azure-linux:azure-linux-4-gen2:latest`).
The image MUST be RHEL-family: cloud-init uses `dnf` and `update-ca-trust`.

For arm64, set `node_arch = "arm64"` and supply an arm64 SKU explicitly:
```hcl
node_arch    = "arm64"
vm_size      = "Standard_D4ps_v5"
os_image_urn = "MicrosoftCBLMariner:azure-linux:azure-linux-4-arm64:latest"
```

## SSH key requirement

Azure Linux VMs with `disable_password_authentication = true` require an SSH public key.
Provide one via `admin_ssh_public_key`. The NSG denies port 22 — this key cannot be used
to log in remotely.

## Out of scope

- Azure resource group / VNet / subnet creation
- NSG rules at the VNet or subnet level (use your consumer repo)
- DNS zones (create and manage separately; pass `dns_zone_resource_group` to wire records)
- Azure role assignments / Managed Identity (add in consumer repo as needed)

## Testing

```bash
cd modules/node-azure
tofu init -backend=false && tofu test   # offline — mock_provider "azurerm", no credentials
```

Real `plan`/`apply` against Azure is run from a consumer repo.
