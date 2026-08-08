# proxmox-cluster

A thin wrapper that composes [`proxmox-control-plane`](../proxmox-control-plane/README.md)
and [`proxmox-node-pool`](../proxmox-node-pool/README.md) into a single Terraform state,
for operators who want one Terragrunt directory per cluster instead of today's split
`control-plane/` + `node-pools/*` layout. It changes nothing about either composed
module internally — it only calls them from one place.

## Single state, single lock

This module puts the control plane and every worker pool in **one Terraform state
with one lock**. That buys a single `terragrunt apply` per cluster, at a real cost:
you can no longer apply `control-plane` and a node pool concurrently from separate
terminals — every change to this cluster serializes through the one state/lock, the
same as any other single-directory Terraform unit. If your workflow depends on
applying a worker pool while a separate control-plane change is in flight, stay on
the split `proxmox-control-plane` + `proxmox-node-pool` layout instead (see below).

## Inputs

Every input `proxmox-control-plane` accepts is available unchanged — same name,
type, default, and validation — at this module's own top level. See
[`proxmox-control-plane`'s README](../proxmox-control-plane/README.md) and its
`variables.tf` for the full list and field-by-field semantics; this module does not
re-document them.

One additional input, `node_pools`, is a map of worker pools keyed by pool name
(e.g. `"pool-a"`). Each entry's fields mirror `proxmox-node-pool`'s own
`variables.tf` exactly, minus `cluster_name` and `cluster_agent_token` — this module
supplies both automatically from its own `cluster_name` input and from
`module.control_plane`'s generated token, so don't (and can't) set them per pool. An
empty `node_pools` map (the default) creates no worker pools — a control-plane-only
cluster, identical in shape to applying `proxmox-control-plane` alone.

### The `dns` provider

Like `proxmox-control-plane` and `proxmox-node-pool`, this module never configures
the `dns` provider itself — it declares `configuration_aliases = [dns]` and expects
its caller to pass one in. Your root module (or your Terragrunt `generate` block)
needs a `provider "dns" {}` block and must pass it through explicitly:

```hcl
provider "dns" {
  alias = "cluster"
  update {
    server        = coalesce(var.dns_server_address, "127.0.0.1")
    port          = var.dns_server_port
    transport     = var.dns_transport
    key_name      = local.tsig_key_name_fqdn
    key_algorithm = var.tsig_key_algorithm
    key_secret    = coalesce(var.tsig_key_secret, "dW51c2VkAA==")
  }
}

module "cluster" {
  source    = "path/to/kube-compute/modules/proxmox-cluster"
  providers = { dns = dns.cluster }
  # ...
}
```

This is required even when you never set `dns_server_address` (DNS registration
stays fully optional and off by default — the provider block just needs to exist so
Terraform can resolve the alias).

## Usage: control-plane only, no worker pools

```hcl
module "cluster" {
  source    = "path/to/kube-compute/modules/proxmox-cluster"
  providers = { dns = dns.cluster }

  cluster_name          = "example"
  proxmox_node           = "pve-01"
  vm_cores               = 4
  vm_memory_mb            = 8192
  vm_disk_gb              = 60
  allowed_ingress_cidrs   = ["10.0.0.0/24"]
  proxmox_template_vm_id  = 9000
}
```

This is equivalent to today's `control-plane/` unit alone — `node_pools` defaults to
`{}`, so no `proxmox-node-pool` instances are created.

## Usage: control plane plus a worker pool

```hcl
module "cluster" {
  source    = "path/to/kube-compute/modules/proxmox-cluster"
  providers = { dns = dns.cluster }

  cluster_name          = "example"
  cluster_type          = "dedicated_control_plane"
  proxmox_node           = "pve-01"
  vm_cores               = 4
  vm_memory_mb            = 8192
  vm_disk_gb              = 60
  allowed_ingress_cidrs   = ["10.0.0.0/24"]
  proxmox_template_vm_id  = 9000
  cluster_network_cidr    = "10.0.0.0/24"

  node_pools = {
    pool-a = {
      proxmox_node           = "pve-01"
      vm_cores               = 4
      vm_memory_mb            = 16384
      vm_disk_gb              = 100
      proxmox_template_vm_id  = 9000
      desired_count           = 2
      registration_address    = "10.0.0.5"
    }
  }
}
```

Each key in `node_pools` becomes one `proxmox-node-pool` instance, wired to this
cluster's `cluster_name` and `cluster_agent_token` automatically. Add more entries
for more pools (e.g. `pool-b` with a different sizing) — the map has no fixed size.

## Cluster autoscaler (optional)

`cluster_autoscaler_enabled`, `cluster_autoscaler_worker_min_size`,
`cluster_autoscaler_worker_max_size`, and `cluster_autoscaler_worker_template` pass
straight through to `proxmox-control-plane` (and from there to `node-bootstrap`,
which renders the actual `MachineDeployment`/CAPI manifests — see
[`node-bootstrap`'s README](../node-bootstrap/README.md#cluster-autoscaler-optional-proxmox-only-today)
for the full mechanics). `false` (the default) is a no-op — no CAPI install, no
MachineDeployment, no change to what this module already provisions.

When enabling it, `cluster_autoscaler_worker_template.proxmox_template_vm_id` must
point at the **`proxmox-autoscaler-worker`** kube-image variant — a different
template than the `proxmox_template_vm_id` used above for control-plane/node-pool
VMs. `cluster_autoscaler_worker_max_size` must be greater than its `0` default, and
`cluster_autoscaler_worker_template` must be set; both are enforced by `plan`-time
validation so an incomplete configuration fails with a clear error rather than
producing a MachineDeployment that can never scale.

## Existing standalone modules remain fully supported

`proxmox-control-plane` and `proxmox-node-pool` are unchanged and continue to work
exactly as before, applied as separate Terragrunt units with a `dependency` block
carrying `cluster_agent_token` between them. `proxmox-cluster` is an additional
option for consumers who want a single directory/state per cluster — it does not
deprecate, replace, or require migrating the split layout.
