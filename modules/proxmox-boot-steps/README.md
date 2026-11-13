# proxmox-boot-steps

Renders the boot steps and files that only a Proxmox node needs. It produces text and creates no resource.

Pass the `steps` output to `provider_steps` and the `files` output to `provider_files` of `node-bootstrap`.

## Steps

- `iscsi-initiator` runs when `iscsi_initiator_enabled` is true. It writes a fixed iSCSI initiator name and restarts `iscsid`. An iSCSI target can then allow-list the initiator once, before any VM rebuild. The image must have `iscsi-initiator-utils`.
- `dns-self-register` runs when `dns_self_register_zone` is set. The genesis node publishes a single-target A record through RFC2136 `nsupdate`, as soon as it knows its own IP. Set it on the genesis node only.

The `files` output carries the TSIG key, so it is sensitive.

## Inputs

| Name | Purpose |
|------|---------|
| `cluster_name` | Required. Part of the iSCSI initiator name. |
| `node_name` | Required. Names the iSCSI initiator when `node_fqdn_label` is null. |
| `node_fqdn_label` | Short label that names the iSCSI initiator. Default `null`, which uses `node_name`. |
| `iscsi_initiator_enabled` | Turns on the `iscsi-initiator` step. Default `true`. |
| `dns_self_register_zone` | DNS zone, with a trailing dot, for the self-registered record. Default `null`, which turns the step off. |
| `dns_self_register_record_name` | Record name, relative to the zone. Required when the zone is set. |
| `dns_self_register_ttl` | TTL of the record, in seconds. Default `30`. |
| `dns_server_address` | Address of the RFC2136 DNS server. Required when the zone is set. |
| `dns_server_port` | Port of the DNS server. Default `53`. |
| `dns_transport` | Transport of `nsupdate`: `udp`, `tcp`, `udp4`, `udp6`, `tcp4` or `tcp6`. Default `udp`. |
| `tsig_key_name` | Name of the TSIG key. Required when the zone is set. |
| `tsig_key_algorithm` | Algorithm of the TSIG key. Default `hmac-sha256`. |
| `tsig_key_secret` | Base64 TSIG key secret. Sensitive. Required when the zone is set. |

The `steps` and `files` outputs are described above.

The `dns_server_*` and `tsig_*` inputs configure the DNS update. They are ignored while `dns_self_register_zone` is null.

Keep `dns_self_register_ttl` low. A caching resolver in front of the DNS server keeps the last answer for up to the TTL. On a reused record name, a long TTL delays every joining node.
