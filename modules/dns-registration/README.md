# dns-registration

Publishes a DNS A record set via RFC2136 dynamic update (TSIG-authenticated),
by shelling out to `nsupdate`. That's the whole scope — this module neither
creates the zone nor the TSIG key; both must already exist on the target DNS
server before this module runs.

**Provider-neutral, not Proxmox-specific**, despite currently only being wired
in by `proxmox-control-plane`/`proxmox-node-pool`. AWS and Azure have their own
native DNS APIs (Route53, Azure DNS) instead, and Proxmox has no managed-DNS
equivalent — that's why Proxmox is the only current caller, not because
RFC2136 is Proxmox-bound. Any consumer running their own RFC2136-compliant DNS
server (self-hosted, Technitium, BIND, PowerDNS, etc.) is a legitimate future
caller without a rename.

## What this module does

Given a zone, a record name, a list of addresses, and TSIG credentials, it
runs an `nsupdate` transaction that deletes any existing record set at that
name and re-adds every address under it — clients resolve the name once and
get every current address back, picking one themselves.

## Why `nsupdate` instead of the `hashicorp/dns` provider

This module used to be a single `dns_a_record_set` resource via
`hashicorp/dns`. A real apply against Technitium found every dynamic update
that provider sent — add or delete — rejected with `NOTIMP (4)`, while the
byte-for-byte equivalent operation via `nsupdate` succeeded every time
(verified repeatedly: fresh test records, the actual production records, both
TCP and UDP transports). node-bootstrap's own genesis self-registration
already used `nsupdate` for the same reason (see its `bootstrap.sh.tftpl`) and
has never hit this. The exact root cause inside `hashicorp/dns`'s RFC2136
wire encoding was never pinned down — not worth chasing further once
`nsupdate` was proven reliable end-to-end.

**Requires `nsupdate`** (`bind-utils` on RHEL/Alma, `dnsutils` on
Debian/Ubuntu) on the machine running `tofu apply`/`tofu destroy`.

## Why this record shape

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
  formed) with a different mechanism entirely (a local `nsupdate` exec, not
  Ansible). Separation lets the caller decide *when* to invoke it (typically
  `depends_on` a control plane's node-bootstrap calls succeeding).

## Inputs of note

- `dns_zone` must be a trailing-dot FQDN (`"lan."`, not `"lan"`); `record_name`
  is relative to it (`"api.cluster-3"`, not the full name).
- `enabled` (default `true`): set `false` and no record is published.
- `dns_server_address`/`dns_server_port`/`dns_transport`/`tsig_key_*`: the
  connection details `nsupdate` needs. No `provider` block to configure —
  every caller passes these as plain module inputs.

## How the update runs, and why the secret never touches state

A single `terraform_data` resource per record, with a create-time
`local-exec` provisioner running the `nsupdate` transaction and a
`when = destroy` provisioner running the corresponding delete. The non-secret
connection details (zone, name, addresses, TTL, server, TSIG key *name*/
*algorithm*) go through `terraform_data`'s `input`/`output`, which Terraform
does persist to state — fine, since none of it is secret, and it's what lets
the destroy-time provisioner still know what to delete after the resources
that originally supplied those values (e.g. a VM's IP) are already gone.

`tsig_key_secret` is deliberately **not** part of `input`. It's passed to
`nsupdate` only via each provisioner's own `environment` block (an
env var Terraform evaluates at apply/destroy time, never written into any
resource attribute), matching this project's hard rule that secrets never
touch state in plaintext. Referencing it directly in the destroy-time
provisioner is safe despite the usual "destroy-time provisioners can't
reference other resources" restriction — that restriction is about values
that transitively depend on another *resource* (which may already be gone by
destroy time); `tsig_key_secret` is a leaf module input sourced straight from
a root `TF_VAR_*`, with no such dependency.

Any change to the tracked inputs (`triggers_replace`) forces a full
destroy+create instead of an in-place update, because `terraform_data`'s
create-time provisioner only runs on actual creation — an in-place update
alone wouldn't rerun `nsupdate` with the new values.

## What this module does *not* do

- Create the DNS zone or TSIG key — both are prerequisites set up on the DNS
  server directly (server-side config, not something this module manages).
- Decide *when* to run relative to a control plane forming, or compute
  `dns_zone`/`record_name` from a cluster's naming convention — the caller's
  job (e.g. `proxmox-control-plane` derives these from its own
  `cluster_fqdn`/`cluster_domain` locals).
