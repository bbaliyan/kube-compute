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
server (self-hosted, BIND, PowerDNS, etc.) is a legitimate future
caller without a rename.

## What this module does

Given a zone, a record name, a list of addresses, and TSIG credentials, it
runs an `nsupdate` transaction that deletes any existing record set at that
name and re-adds every address under it — clients resolve the name once and
get every current address back, picking one themselves.

## Why `nsupdate` instead of the `hashicorp/dns` provider

Some DNS servers reject every dynamic update that the `hashicorp/dns` provider sends with
`NOTIMP (4)`. The same operation through `nsupdate` succeeds on both TCP and UDP.
The genesis self-registration step of `proxmox-boot-steps` also uses `nsupdate`.

- **A dedicated module, not folded into `node-bootstrap`.** `node-bootstrap`
  installs/joins one node given a role already assigned by the caller; this
  is a separate, later step (only meaningful once a control plane has
  formed) with a different mechanism entirely (a local `nsupdate` exec). Separation lets the caller decide *when* to invoke it (typically
  `depends_on` a control plane's node-bootstrap calls succeeding).

## Inputs of note

- `dns_zone` must be a trailing-dot FQDN (`"lan."`, not `"lan"`); `record_name`
  is relative to it (`"api.my-cluster"`, not the full name).
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

`tsig_key_secret` is deliberately **not** part of `input`, matching this
project's hard rule that secrets never touch state in plaintext. The
create-time provisioner gets it through its own `environment` block. A
destroy-time provisioner may reference nothing but `self`, so the delete reads
`TF_VAR_tsig_key_secret` from the environment `tofu destroy` runs in, and skips
the cleanup with a warning when it isn't set.

Both provisioners run under `/bin/bash`: `local-exec` defaults to `/bin/sh`,
which on Debian is dash, and dash has no `pipefail`.

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

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_dns_server_address"></a> [dns\_server\_address](#input\_dns\_server\_address) | Hostname or IPv4 address of the RFC2136-compliant DNS server to publish to. | `string` | n/a | yes |
| <a name="input_dns_server_port"></a> [dns\_server\_port](#input\_dns\_server\_port) | Port the DNS server accepts dynamic updates on. | `number` | `53` | no |
| <a name="input_dns_transport"></a> [dns\_transport](#input\_dns\_transport) | Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. | `string` | `"udp"` | no |
| <a name="input_dns_zone"></a> [dns\_zone](#input\_dns\_zone) | DNS zone the record belongs to. Must be an FQDN including the trailing dot (e.g. 'lan.'). | `string` | n/a | yes |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Whether to publish the record. false is a no-op (no resource created). | `bool` | `true` | no |
| <a name="input_record_addresses"></a> [record\_addresses](#input\_record\_addresses) | IPv4 addresses this record should resolve to. A record set, not one record per address — every address is published under the same name. | `list(string)` | n/a | yes |
| <a name="input_record_name"></a> [record\_name](#input\_record\_name) | Record name, relative to dns\_zone (e.g. 'api.my-cluster' for zone 'example.test.' registers 'api.my-cluster.example.test.'). | `string` | n/a | yes |
| <a name="input_record_ttl"></a> [record\_ttl](#input\_record\_ttl) | TTL in seconds for the record. | `number` | `300` | no |
| <a name="input_tsig_key_algorithm"></a> [tsig\_key\_algorithm](#input\_tsig\_key\_algorithm) | TSIG key algorithm: 'hmac-md5', 'hmac-sha1', 'hmac-sha256', or 'hmac-sha512'. Must match how the key was created on the DNS server. | `string` | n/a | yes |
| <a name="input_tsig_key_name"></a> [tsig\_key\_name](#input\_tsig\_key\_name) | Name of the TSIG key configured on the DNS server, used to authenticate the dynamic update. | `string` | n/a | yes |
| <a name="input_tsig_key_secret"></a> [tsig\_key\_secret](#input\_tsig\_key\_secret) | Base64-encoded TSIG shared secret. Sensitive — supply via a TF\_VAR\_* environment variable, never committed. Deliberately kept out of every tracked resource attribute (see README) so it never lands in state; passed to nsupdate only as a process environment variable at apply/destroy time. | `string` | n/a | yes |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_fqdn"></a> [fqdn](#output\_fqdn) | The fully-qualified name this module registered (record\_name + dns\_zone). |
| <a name="output_record_created"></a> [record\_created](#output\_record\_created) | Whether the record was actually published this run (mirrors var.enabled). |
<!-- END_TF_DOCS -->
