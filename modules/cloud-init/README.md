# cloud-init

Provider-agnostic renderer for the RKE2 node cloud-init. **No provider resources** —
it only renders a template, so it builds and tests with zero cloud credentials.

## Inputs

See `variables.tf`. All environment-specific inputs are nullable; pass only what your
environment needs. `trusted_ca_pem`, `registry_mirror_url`, the `gitops_*` inputs, and
`cni` gate optional cloud-init sections.

> Two bootstrap paths currently coexist in this codebase: `aws-control-plane` and both
> `proxmox-*` modules bootstrap RKE2 via `node-bootstrap`'s Ansible role instead of this
> module's cloud-init template. `azure-control-plane`, `azure-node-pool`, and
> `aws-node-pool` still attach this module's template as boot-time `user_data` — for
> those three, everything below is live, not a fallback.

- **`cni`** (default `"cilium"`) — container network interface. When set to `"cilium"`,
  the module renders RKE2 config keys `cni: cilium` / `disable-kube-proxy: true` on every
  server and installs Cilium via a HelmChart CR with `bootstrap: true` written to RKE2's
  own `/var/lib/rancher/rke2/server/manifests/` (Cilium must exist before the node goes
  Ready, so it uses RKE2's own bootstrap-manifest mechanism, not the post-Ready
  `/etc/kube-compute/manifests/` + kubectl-apply path used for Argo/platform).
  
  Implemented in the AlmaLinux 10 cloud-init template.

  `cilium_operator_replicas` (default `null`, meaning Cilium's own chart default of `2` with
  pod anti-affinity) controls `operator.replicas`. On a genuinely single-node cluster the
  chart default leaves one `cilium-operator` replica permanently `Pending` — the cluster still
  comes up networked, but that second replica never schedules — so `azure-control-plane` passes
  `1` explicitly when `control_plane_count = 1` (as does `node-bootstrap`'s equivalent variable,
  used the same way by `aws-control-plane` and `proxmox-control-plane`).

## Outputs

- `cloud_init` (sensitive) — plaintext rendered cloud-config (for debugging/tests).
- `user_data_base64` (sensitive) — `base64gzip` form for VM user-data attachment.

## Testing

```bash
cd modules/cloud-init
tofu init -backend=false && tofu test    # content assertions
tests/validate-render.sh                 # YAML parse + bash -n of the full render
```
