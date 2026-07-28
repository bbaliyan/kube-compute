# dns-registration

Publishes a DNS A record set via RFC2136 dynamic update (TSIG-authenticated),
using the `hashicorp/dns` provider. That's the whole scope — this module
neither creates the zone nor the TSIG key; both must already exist on the
target DNS server before this module runs.

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

- `tsig_key_secret` is `sensitive` — supply it via a `TF_VAR_*` environment
  variable, never commit it. This module doesn't care where the caller
  sourced it from (a plain env var, a secret manager read elsewhere, etc.).
- `dns_zone` must be a trailing-dot FQDN (`"lan."`, not `"lan"`); `record_name`
  is relative to it (`"api.cluster-3"`, not the full name).

## What this module does *not* do

- Create the DNS zone or TSIG key — both are prerequisites, set up on the DNS
  server directly (out of Terraform's hands, since that's server-side config,
  not a resource this provider manages).
- Decide *when* to run relative to a control plane forming, or compute
  `dns_zone`/`record_name` from a cluster's own naming convention — that's the
  caller's job (e.g. `proxmox-control-plane` derives these from its own
  `cluster_fqdn`/`cluster_domain` locals).
