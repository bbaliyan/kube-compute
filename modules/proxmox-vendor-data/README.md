# proxmox-vendor-data

Renders the cloud-init vendor data that every Proxmox VM of a cluster shares. It creates no resource. `proxmox-control-plane` and `proxmox-node-pool` upload its `data` output as a snippet.

The document:

- makes the systemd journal persistent, so the log of a boot that hangs survives a reset,
- adds `ssh_authorized_keys` to the default cloud user, when the keys are set,
- enables the QEMU guest agent and a login on the serial console `ttyS0`.

It is built with `yamlencode`, so an SSH key is always a valid YAML string.

## Usage

```hcl
module "vendor_data" {
  source = "../proxmox-vendor-data"

  ssh_authorized_keys = var.ssh_authorized_keys
}
```

Pass `module.vendor_data.data` to the `source_raw.data` of a `proxmox_virtual_environment_file` snippet.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_ssh_authorized_keys"></a> [ssh\_authorized\_keys](#input\_ssh\_authorized\_keys) | SSH public keys for the default cloud user. Null writes no ssh\_authorized\_keys key. | `list(string)` | `null` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_data"></a> [data](#output\_data) | The '#cloud-config' vendor data document, for a proxmox\_virtual\_environment\_file snippet wired to initialization.vendor\_data\_file\_id. |
<!-- END_TF_DOCS -->
