# proxmox-boot-steps

Renders the boot steps and files that only a Proxmox node needs. It produces text and creates no resource.

Pass the `steps` output to `provider_steps` and the `files` output to `provider_files` of `node-bootstrap`.

## Steps

- `iscsi-initiator` runs when `iscsi_initiator_prefix` is set. It writes a fixed iSCSI initiator name and restarts `iscsid`. An iSCSI target can then allow-list the initiator once, before any VM rebuild. The image must have `iscsi-initiator-utils`.
- `dns-self-register` runs when `dns_self_register_zone` is set. The genesis node publishes a single-target A record through RFC2136 `nsupdate`, as soon as it knows its own IP. Set it on the genesis node only.

The `files` output carries the TSIG key, so it is sensitive.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster name. Part of the iSCSI initiator name. | `string` | n/a | yes |
| <a name="input_dns_self_register_record_name"></a> [dns\_self\_register\_record\_name](#input\_dns\_self\_register\_record\_name) | Record name, relative to dns\_self\_register\_zone (e.g. 'genesis.my-cluster' for zone 'example.test.' registers 'genesis.my-cluster.example.test.'). Required when dns\_self\_register\_zone is set; ignored otherwise. | `string` | `null` | no |
| <a name="input_dns_self_register_ttl"></a> [dns\_self\_register\_ttl](#input\_dns\_self\_register\_ttl) | TTL in seconds for the self-registered record. Used only when dns\_self\_register\_zone is set. Keep it low: a downstream caching resolver serves a stale record for up to this TTL. | `number` | `30` | no |
| <a name="input_dns_self_register_zone"></a> [dns\_self\_register\_zone](#input\_dns\_self\_register\_zone) | DNS zone (FQDN, trailing dot, e.g. 'lan.') the genesis node registers a single-target A record in through RFC2136 nsupdate. Null or empty (the default) disables it, and every dns\_self\_register\_*, dns\_server\_* and tsig\_* variable is ignored. Set it on the genesis node only. | `string` | `null` | no |
| <a name="input_dns_server_address"></a> [dns\_server\_address](#input\_dns\_server\_address) | RFC2136 DNS server address the genesis node sends its nsupdate request to. Required when dns\_self\_register\_zone is set; ignored otherwise. | `string` | `null` | no |
| <a name="input_dns_server_port"></a> [dns\_server\_port](#input\_dns\_server\_port) | RFC2136 DNS server port. Only meaningful when dns\_self\_register\_zone is set. | `number` | `53` | no |
| <a name="input_dns_transport"></a> [dns\_transport](#input\_dns\_transport) | Transport nsupdate uses to reach dns\_server\_address: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'. Only meaningful when dns\_self\_register\_zone is set. | `string` | `"udp"` | no |
| <a name="input_iscsi_initiator_prefix"></a> [iscsi\_initiator\_prefix](#input\_iscsi\_initiator\_prefix) | Prefix of the fixed iSCSI initiator name, in the form iqn.<yyyy-mm>.<reversed domain>, for example iqn.2026-01.test.example. A node writes <prefix>:<cluster\_name>-<node label>, so a target can allow-list it before a rebuild. Null keeps the OS name. The image needs iscsi-initiator-utils. | `string` | `null` | no |
| <a name="input_node_fqdn_label"></a> [node\_fqdn\_label](#input\_node\_fqdn\_label) | Short label that names the iSCSI initiator. Null uses node\_name. | `string` | `null` | no |
| <a name="input_node_name"></a> [node\_name](#input\_node\_name) | Node name. Names the iSCSI initiator when node\_fqdn\_label is null. | `string` | n/a | yes |
| <a name="input_tsig_key_algorithm"></a> [tsig\_key\_algorithm](#input\_tsig\_key\_algorithm) | TSIG key algorithm (e.g. 'hmac-sha256'). Only meaningful when dns\_self\_register\_zone is set. | `string` | `"hmac-sha256"` | no |
| <a name="input_tsig_key_name"></a> [tsig\_key\_name](#input\_tsig\_key\_name) | TSIG key name authorizing the nsupdate request. Required when dns\_self\_register\_zone is set; ignored otherwise. | `string` | `null` | no |
| <a name="input_tsig_key_secret"></a> [tsig\_key\_secret](#input\_tsig\_key\_secret) | Base64-encoded TSIG key secret. Required when dns\_self\_register\_zone is set; ignored otherwise. Sensitive: cloud-init writes it to a 0600 key file that the step removes after nsupdate. | `string` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_files"></a> [files](#output\_files) | Value for node-bootstrap's provider\_files. Sensitive: it carries the TSIG key. |
| <a name="output_steps"></a> [steps](#output\_steps) | Value for node-bootstrap's provider\_steps. |
<!-- END_TF_DOCS -->

The `dns_server_*` and `tsig_*` inputs configure the DNS update. They are ignored while `dns_self_register_zone` is null.

Keep `dns_self_register_ttl` low. A caching resolver in front of the DNS server keeps the last answer for up to the TTL. On a reused record name, a long TTL delays every joining node.
