# dns-registration

Publishes a DNS A record set via RFC2136 dynamic update (TSIG-authenticated),
using the `hashicorp/dns` provider. That's the whole scope — this module
neither creates the zone nor the TSIG key; both must already exist on the
target DNS server before this module runs.

**Provider-neutral, not Proxmox-specific**, despite currently only being wired
in by `proxmox-control-plane`/`proxmox-node-pool`. AWS and Azure have their own
native DNS APIs (Route53, Azure DNS) instead, and Proxmox has no managed-DNS
equivalent — that's why Proxmox is the only current caller, not because
RFC2136 is Proxmox-bound. Any consumer running their own RFC2136-compliant DNS
server (self-hosted, Technitium, BIND, PowerDNS, etc.) is a legitimate future
caller without a rename.

## What this module does

One `dns_a_record_set` resource: given a zone, a record name, a list of
addresses, and TSIG credentials, it writes (creates or updates) a single
record set publishing every address under one name — clients resolve the name
once and get every current address back, picking one themselves.

## Why this shape

- **A plain multi-address record set, not health-checked/actively-updated.**
  RKE2 agents don't depend on the record staying accurate after their first
  successful join — they self-discover control-plane peers via the cluster's
  own internal API afterward. `kubectl`/`client-go` already retry
  sequentially across every resolved address, so a stale entry costs one
  failed attempt, not a hard failure. No custom failover logic needed.
- **RFC2136 over a provider's native API**, where the DNS server offers a
  choice — TSIG keys scope tighter than a broad API token, and it works
  against any RFC2136-compliant server, not one product's API.
- **A dedicated module, not folded into `node-bootstrap`.** `node-bootstrap`
  installs/joins one node given a role already assigned by the caller; this
  is a separate, later step (only meaningful once a control plane has
  formed) with a different mechanism entirely (a DNS provider, not Ansible).
  Separation lets the caller decide *when* to invoke it (typically
  `depends_on` a control plane's node-bootstrap calls succeeding).

## Inputs of note

- `dns_zone` must be a trailing-dot FQDN (`"lan."`, not `"lan"`); `record_name`
  is relative to it (`"api.cluster-3"`, not the full name).
- `enabled` (default `true`): set `false` and no record is created. Lets a
  caller gate DNS registration without wrapping this module call in
  `count`/`for_each` (see below for why that matters).

## Provider configuration: the caller's job, not this module's

This module has no `provider "dns" {}` block. `hashicorp/dns` signs every
dynamic update using TSIG credentials configured at the *provider* level
(server/port/transport/key), not per resource. Terraform forbids
`count`/`for_each`/`depends_on` on a module call targeting a module that owns
its own provider config block (a "legacy module"). Callers invoking this
module virtually always need `depends_on` — to sequence the DNS write after a
control plane has actually formed — so the `provider "dns" {}` block and its
`dns_server_address`/`tsig_key_*` inputs live in the **caller** instead, which
then passes its configured provider down explicitly:

```hcl
provider "dns" {
  update {
    server        = var.dns_server_address
    port          = var.dns_server_port
    transport     = var.dns_transport
    key_name      = "${trimsuffix(var.tsig_key_name, ".")}."  # provider needs a trailing dot
    key_algorithm = var.tsig_key_algorithm
    key_secret    = var.tsig_key_secret  # sensitive — supply via a TF_VAR_* env var, never commit
  }
}

module "dns_registration" {
  source     = "../dns-registration"
  providers  = { dns = dns }
  depends_on = [module.node_bootstrap]
  enabled    = var.dns_server_address != null
  dns_zone   = "lan."
  record_name      = "api.${var.cluster_name}"
  record_addresses = [...]
}
```

See `proxmox-control-plane` for the concrete implementation of this pattern.

## What this module does *not* do

- Configure the `dns` provider — the caller's job, per above.
- Create the DNS zone or TSIG key — both are prerequisites set up on the DNS
  server directly (server-side config, not a resource this provider manages).
- Decide *when* to run relative to a control plane forming, or compute
  `dns_zone`/`record_name` from a cluster's naming convention — the caller's
  job (e.g. `proxmox-control-plane` derives these from its own
  `cluster_fqdn`/`cluster_domain` locals).
