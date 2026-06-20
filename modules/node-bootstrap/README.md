# node-bootstrap

Provider-agnostic renderer for the K3s node cloud-init. **No provider resources** —
it only renders a template, so it builds and tests with zero cloud credentials.

## Inputs

See `variables.tf`. All environment-specific inputs are nullable; pass only what your
environment needs. `trusted_ca_pem`, `registry_mirror_url`, and the `gitops_*` inputs
gate optional cloud-init sections.

## Outputs

- `cloud_init` (sensitive) — plaintext rendered cloud-config (for debugging/tests).
- `user_data_base64` (sensitive) — `base64gzip` form for VM user-data attachment.

## Testing

```bash
cd modules/node-bootstrap
tofu init -backend=false && tofu test    # content assertions
tests/validate-render.sh                 # YAML parse + bash -n of the full render
```
