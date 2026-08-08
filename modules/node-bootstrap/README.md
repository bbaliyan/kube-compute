# node-bootstrap

Renders a `#cloud-config` document for **one node**, given a role already
assigned by the caller (`server-init`, `server-join`, or `worker`). This
module never decides how many nodes exist or which role each gets — that
stays in the provider modules.

## What this module does — and does not do

This module executes nothing and creates no resources of its own. There is no
`null_resource`, no `local-exec`, no connection of any kind to the node, no
Ansible, and (unlike an earlier version of this module) no `data.external`
Helm render at plan time either. Its single meaningful output is
`cloud_init_user_data` — a complete cloud-init document (hostname, RKE2
`config.yaml`/`registries.yaml`/trusted-CA/manifest payloads as base64
`write_files`, and a `runcmd` that invokes an on-node bootstrap script). The
caller is responsible for attaching that output to its VM as user-data; this
module has no resource to `depends_on`.

The heavy half of bootstrap — OS prep, RKE2 binaries, SELinux policy, kernel
modules, the guest agent, **and the genesis Cilium/Argo CD manifests** — is
expected to already be baked into the image the caller boots the VM from (a
"kube-image" template; see its `packer/proxmox/build.sh` and `helm-values/`
for where that render actually happens now). This module only renders the
per-cluster identity, per-cluster secrets, and join logic that can never be
baked into a shared image. `modules/proxmox-control-plane` and
`modules/proxmox-node-pool` are the only callers currently wired for this —
both accept an optional `proxmox_template_vm_id` to full-clone a pre-baked
image, alongside their older stock-cloud-image paths.

## Cilium/Argo CD are baked, not rendered here

An earlier version of this module shelled out to `helm template` at plan
time (via a `data.external` source) and embedded the rendered manifest whole
in the cloud-init payload. That stopped working for real: Argo CD's chart
alone renders to ~1.9 MB, and Proxmox's `cicustom` snippet upload has a hard
1 MiB cap — a real `tofu apply` against `cluster-1` failed with
`file '...' too long - aborting`. The render moved to kube-image's Packer
build instead (once, at bake time, not on every `tofu apply`); this module's
`render_cilium`/`render_argocd` locals now only decide whether `bootstrap.sh`
applies the files kube-image already put at
`/opt/kube-compute/manifests/{cilium.yaml,00-argocd.yaml}` on the template —
a per-cluster runtime decision (CNI choice, GitOps enablement), independent
of whether the files exist (they always do, on a kube-image-baked template).

## Watching progress during a real apply

Terraform/OpenTofu returns as soon as the cloud-init payload is attached to
the VM — it has no way to know when (or whether) the node actually joins the
cluster, because nothing in this module executes anything. All of that now
happens asynchronously on the node itself, after `apply` has already
returned. The node writes its own progress to
`/var/log/kube-compute-bootstrap.log`; that log is the only place to watch
bootstrap progress. There is no Terraform-visible signal, no provisioner
output, and no `bootstrap_log_path`-style output to depend on.

## Cluster autoscaler (optional, Proxmox-only today)

`cluster_autoscaler_enabled = true` has this module render an extra genesis-only
manifest (`ProxmoxMachineTemplate` + `MachineDeployment` + `RKE2ConfigTemplate`) and
the `bootstrap.sh` apply steps that install CAPI/CAPMOX/CAPRKE2 and hand the
MachineDeployment to cluster-autoscaler. It is genesis-only (rendered on
`server-init` nodes only) and independent of `gitops_platform_enabled` — the CAPI
install/apply is a one-time step, not tied to whether a platform Argo CD
Application also exists on this cluster.

Two things to get right when enabling it:

- `cluster_autoscaler_worker_template.proxmox_template_vm_id` must point at the
  **`proxmox-autoscaler-worker`** kube-image variant, not the normal
  control-plane/pool image — CAPMOX full-clones this template for every
  autoscaled worker it provisions, so it needs to already carry the RKE2 agent
  bits and CAPI-facing bootstrap contract that variant bakes in. Pointing it at
  a control-plane or ordinary node-pool template will not fail at `plan` time
  but produces workers that never join correctly.
- `cluster_autoscaler_worker_max_size` must be set above its `0` default, and
  `cluster_autoscaler_worker_template` must be set, whenever
  `cluster_autoscaler_enabled = true` — both are enforced by variable
  `validation` blocks so a misconfiguration fails at `plan` with a clear
  message instead of a raw "Attempt to get attribute from null value" error
  (or a MachineDeployment that can never scale up).
- `gitops_platform_enabled = true` clusters also get a `clusterAutoscalerEnabled`
  Helm parameter passed to the `platform` Argo CD Application, mirrored from
  this same `cluster_autoscaler_enabled` value — that's what gates
  kube-platform's own `cluster-autoscaler` Application so it only syncs on
  clusters that opted in.

## Interface notes

- `ansible_playbook_path`, `invocation_mode`, `ansible_connection_vars`,
  `on_node_bundle`, `on_node_secret_env`, `node_provider`, `bootstrap_id`,
  `cilium_version`, `argocd_version`, and `cilium_operator_replicas` are all
  gone. There is no playbook, no `null_resource`, no on-node bundle, no
  provider branching, and no Helm render in this module — the two version
  variables had no effect once kube-image took over the render (both
  versions are now baked into the template, resolved from kube-platform's
  `platform-versions.yaml` at kube-image build time), and
  `cilium_operator_replicas` had nowhere left to reach once the render was no
  longer per-cluster (kube-platform's own `cilium-app.yaml` already
  hardcodes `replicas: 1` with no topology signal of its own, and overwrites
  any genesis-time value within moments of Argo CD's first `selfHeal`
  reconcile regardless — this was already the effective end state on every
  topology).
- `cni` defaults to `"cilium"` (eBPF dataplane, no iptables/ipset/xtables
  dependency — the only variant verified against AlmaLinux 10). When
  `cni = "cilium"` on a genesis node, the module has `bootstrap.sh` apply the
  Cilium manifest kube-image already baked onto the template, and sets
  `disable: [rke2-cilium]` in `config.yaml` so RKE2's own built-in HelmChart
  install of Cilium never runs alongside it. `"default"` remains selectable
  only as an escape hatch for a consumer-supplied image/template that ships a
  different CNI out of the box.
- `cluster_token`/`cluster_agent_token`/`agent_token_fetch_command`/
  `trusted_ca_pem`/`tsig_key_secret` are all `sensitive = true` and flow only
  into the cloud-init payload's base64-encoded `write_files` (a 0600
  `/opt/kube-compute/secrets.env`, sourced by the bootstrap script on the
  node) — never as plaintext Terraform state elsewhere, never over any
  inbound connection. `server-join` receives `cluster_token` the same direct
  way `server-init` does; only `worker` uses the fetch-command pattern, since
  a worker joins an already-existing cluster and pulls its token from the
  provider's own secret store instead.
- `modules/aws-*` and `modules/azure-*` still reference the pre-cutover
  interface (`node_provider`, `ansible_playbook_path`, `invocation_mode`,
  `ansible_connection_vars`, `bootstrap_id`, `on_node_bundle`,
  `on_node_secret_env`) and do not currently validate against this module.
  Proxmox is the only provider with an end-to-end working path today;
  updating AWS/Azure is tracked as separate follow-up work, not part of this
  module's current interface.
