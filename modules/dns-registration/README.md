# dns-registration

Publishes a DNS A record set via RFC2136 dynamic update (TSIG-authenticated),
using the `hashicorp/dns` provider. That's the whole scope — this module
neither creates the zone nor the TSIG key; both must already exist on the
target DNS server before this module runs.

**Provider-neutral, not Proxmox-specific**, despite currently only being wired
in by `proxmox-control-plane`/`proxmox-node-pool`. AWS and Azure have their own
native DNS APIs (Route53, Azure DNS) as their optional-DNS path instead, and
Proxmox has no managed-DNS equivalent — that's why Proxmox is the only current
caller, not because RFC2136 is Proxmox-bound. Any provider whose consumer runs
their own RFC2136-compliant DNS server (self-hosted, Technitium, BIND, PowerDNS,
etc.) is a legitimate future caller of this module without a rename.

## What this module does

One `dns_a_record_set` resource: given a zone, a record name, a list of
addresses, and TSIG credentials, it writes (creates or updates) a single
record set publishing every address under one name. Not one record per
address — clients resolve the name once and get every current address back,
picking one themselves (or failing over between them, depending on the
client).

## Why this shape

- **A plain multi-address record set, not a health-checked/actively-updated
  one.** Verified against real client behavior: RKE2 agents don't depend on
  the record staying accurate after their first successful join — they
  self-discover control-plane peers via the cluster's own internal API from
  then on. `kubectl`/`client-go` already retry sequentially across every
  address a name resolves to (standard Go `net.Dialer` behavior), so a stale
  entry costs one failed connection attempt, not a hard failure. No custom
  failover logic needed on top of a static record set.
- **RFC2136 over the provider's native API**, where the DNS server offers a
  choice — TSIG keys can be scoped to exactly which records/zones/record
  types they're allowed to touch, tighter than a broad API token, and it
  works against any RFC2136-compliant server rather than one specific
  product's API.
- **A dedicated module, not folded into `node-bootstrap`.** `node-bootstrap`
  installs/joins one node given a role already assigned by the caller; this
  is a separate, later step (only meaningful once a control plane has
  actually formed) with a completely different mechanism (a DNS provider, not
  Ansible). Keeping it separate means a caller decides *when* to invoke it
  (typically `depends_on` a control plane's node-bootstrap calls succeeding)
  rather than this module guessing.

## Inputs of note

- `dns_zone` must be a trailing-dot FQDN (`"lan."`, not `"lan"`); `record_name`
  is relative to it (`"api.cluster-3"`, not the full name).
- `enabled` (default `true`) is a no-op switch: set `false` and no record is
  created. Exists so a caller can gate DNS registration without wrapping this
  module call in `count`/`for_each` (see below for why that matters).

## Provider configuration: the caller's job, not this module's

This module does **not** contain a `provider "dns" {}` block. The
`hashicorp/dns` provider signs every dynamic update using TSIG credentials
configured at the *provider* level (server/port/transport/key), not per
resource — so those credentials have to live somewhere. Terraform's own rule
forces where: a module call that uses `count`, `for_each`, or `depends_on`
cannot target a module that owns its own provider configuration block (a
"legacy module", in Terraform's terms). A caller invoking this module
virtually always needs `depends_on` — the whole point is to sequence the DNS
write after a control plane has actually formed — so the `provider "dns" {}`
block, and the `dns_server_address`/`tsig_key_*` inputs that fill it, live in
the **caller** instead. The caller then passes its configured provider down
explicitly:

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

- Configure the `dns` provider (TSIG server/port/transport/key) — the
  caller's job, per the section above.
- Create the DNS zone or TSIG key — both are prerequisites, set up on the DNS
  server directly (out of Terraform's hands, since that's server-side config,
  not a resource this provider manages).
- Decide *when* to run relative to a control plane forming, or compute
  `dns_zone`/`record_name` from a cluster's own naming convention — that's the
  caller's job (e.g. `proxmox-control-plane` derives these from its own
  `cluster_fqdn`/`cluster_domain` locals).
