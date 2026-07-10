# cloud-init

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
  not the post-Ready `/etc/kube-compute/manifests/` + kubectl-apply path used for Argo/platform).
  
  Implemented identically in both the AL2023 and Ubuntu 26.04 cloud-init templates.

  The rendered Cilium values set no `operator.replicas`, so Cilium's own chart default
  (`2`, with pod anti-affinity) applies. On a genuinely single-node cluster (only reachable
  by explicitly forcing `cni = "cilium"` against a 1-node topology, which otherwise defaults
  to flannel) this leaves one `cilium-operator` replica permanently `Pending` — the cluster
  still comes up networked, but that second replica never schedules. If this matters for
  your use case, override it with a consumer-supplied `HelmChart` values patch setting
  `operator.replicas: 1`.

## Outputs

- `cloud_init` (sensitive) — plaintext rendered cloud-config (for debugging/tests).
- `user_data_base64` (sensitive) — `base64gzip` form for VM user-data attachment.

## Testing

```bash
cd modules/cloud-init
tofu init -backend=false && tofu test    # content assertions
tests/validate-render.sh                 # YAML parse + bash -n of the full render
```
