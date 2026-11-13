# proxmox-boot-steps

Renders the boot steps and files that only a Proxmox node needs. It produces text and creates no resource.

Pass the `steps` output to `provider_steps` and the `files` output to `provider_files` of `node-bootstrap`.

## Steps

- `iscsi-initiator` runs when `iscsi_initiator_enabled` is true. It writes a fixed iSCSI initiator name and restarts `iscsid`. An iSCSI target can then allow-list the initiator once, before any VM rebuild. The image must have `iscsi-initiator-utils`.
- `dns-self-register` runs when `dns_self_register_zone` is set. The genesis node publishes a single-target A record through RFC2136 `nsupdate`, as soon as it knows its own IP. Set it on the genesis node only.

The `files` output carries the TSIG key, so it is sensitive.

## Inputs

The `dns_server_*` and `tsig_*` inputs configure the DNS update. They are ignored while `dns_self_register_zone` is null.

Keep `dns_self_register_ttl` low. A caching resolver in front of the DNS server keeps the last answer for up to the TTL. On a reused record name, a long TTL delays every joining node.
