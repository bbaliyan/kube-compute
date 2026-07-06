# node-bootstrap

Provider-agnostic renderer for the K3s node cloud-init. **No provider resources** —
it only renders a template, so it builds and tests with zero cloud credentials.

## Inputs

See `variables.tf`. All environment-specific inputs are nullable; pass only what your
environment needs. `trusted_ca_pem`, `registry_mirror_url`, the `gitops_*` inputs, and
`cni` gate optional cloud-init sections.

- **`cni`** (default `"flannel"`) — container network interface. When set to `"cilium"`,
  the module renders K3s server flags `--flannel-backend=none --disable-network-policy
  --disable-kube-proxy` on every server and installs Cilium via a HelmChart CR with
  `bootstrap: true` written to K3s's own `/var/lib/rancher/k3s/server/manifests/` (Cilium
  must exist before the node goes Ready, so it uses K3s's own bootstrap-manifest mechanism,
  not the post-Ready `/etc/kube-node/manifests/` + kubectl-apply path used for Argo/platform).
  
  **Currently only implemented in the AL2023 cloud-init template.** The Ubuntu 26.04
  template does not yet take a `cni` input (pre-existing gap — see issue 018/019 for
  Ubuntu template completion).

## Outputs

- `cloud_init` (sensitive) — plaintext rendered cloud-config (for debugging/tests).
- `user_data_base64` (sensitive) — `base64gzip` form for VM user-data attachment.

## Testing

```bash
cd modules/node-bootstrap
tofu init -backend=false && tofu test    # content assertions
tests/validate-render.sh                 # YAML parse + bash -n of the full render
```
