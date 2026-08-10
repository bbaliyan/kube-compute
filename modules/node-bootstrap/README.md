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

## Genesis-apply manifests (generic; cluster-autoscaler is the one caller today)

This module no longer knows anything about cluster-autoscaler, CAPI, or
CAPMOX specifically. It exposes two generic inputs instead:

- `genesis_apply_manifests` — an ordered list of `{path, content}` entries,
  written verbatim under `/opt/kube-compute/manifests/` via `write_files` and
  `kubectl apply -f`'d in order by `bootstrap.sh`. This module does not
  interpret `content` at all.
- `cluster_autoscaler_crd_wait_enabled` — gates a `bootstrap.sh` block that
  applies the kube-image-baked `capi-install.yaml` (CAPI core + CAPMOX
  manifests) and waits for CAPI's core CRDs to be `Established` **before**
  applying the `genesis_apply_manifests` entries. Despite the name, it is not
  cluster-autoscaler-specific — any caller needing CAPI's CRDs to exist first
  can use it.

Both are genesis-only (`server-init` only) and independent of
`gitops_platform_enabled` — a one-time step, not tied to whether a platform
Argo CD Application also exists on this cluster.

The one real caller today is `modules/proxmox-cluster`, which owns the
`cluster_autoscaler_enabled` toggle and everything cluster-autoscaler-specific:
it renders a `Cluster` + `Secret` (containing this same module's own shared
worker `cloud_init_user_data`, via a second `node_bootstrap` instantiation
with `set_hostname = false`) + `ProxmoxMachineTemplate` + `MachineDeployment`
bundle (see that module's README/`templates/cluster-autoscaler-workers.yaml.tftpl`),
passes it in as a single `genesis_apply_manifests` entry, and sets
`cluster_autoscaler_crd_wait_enabled = var.cluster_autoscaler_enabled`. There
is deliberately no `RKE2ConfigTemplate`/CAPRKE2 anywhere in that bundle —
workers join via a plain `Secret` referenced by
`Machine.spec.bootstrap.dataSecretName`, reusing this project's existing
worker cloud-init logic rather than a second bootstrap-provider mechanism.

`proxmox-cluster` also merges a `clusterAutoscalerEnabled` Helm parameter
into `platform_extra_helm_parameters` before it reaches this module — that is
what gates kube-platform's own `cluster-autoscaler` Argo CD Application so it
only syncs on clusters that opted in. This module has no hardcoded knowledge
of that parameter; it is just another entry in the generic
`platform_extra_helm_parameters` map.

## `set_hostname` (for shared, byte-identical cloud-init payloads)

Every caller gets `set_hostname = true` (the default): `hostname`/`fqdn` are
written into cloud-config from `node_name`, required because RKE2/kubelet
registers the node by OS hostname. `set_hostname = false` omits both keys
entirely — the only reason to do this is when the exact same rendered
`cloud_init_user_data` is shared across multiple VMs that cannot each get
their own render (e.g. every replica of a CAPI `MachineDeployment`, via one
Secret referenced by `dataSecretName`). The VM platform's own per-instance
metadata (e.g. CAPMOX/cloud-init's NoCloud `local-hostname`) is relied on
instead to supply a unique hostname — **this specific assumption is
unverified against real hardware**, flagged explicitly as a first
real-cluster check for any `set_hostname = false` caller.

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
- `modules/aws-control-plane` and `modules/aws-node-pool` are now cut over to
  this interface too (AWS cutover, Ticket 02): both call this module with no
  `node_provider`/`ansible_playbook_path`/`ansible_connection_vars` and attach
  `cloud_init_user_data` via AWS's own `user_data_base64 = base64gzip(...)`
  convention, combined via a cloud-init MIME multipart document with a small
  AWS-only SSM-agent-enable script (see those modules' own `main.tf`/README
  for why the MIME combine lives there, not here). `aws-node-pool`'s ASG
  launch template calls this module with `set_hostname = false` since every
  pool member shares one rendered payload — the same pattern
  `proxmox-cluster`'s cluster-autoscaler workers already established.
  `modules/azure-control-plane`/`modules/azure-node-pool` no longer exist as
  working code — they were reduced to placeholders (their prior implementation
  called this module's pre-cutover interface and was never validated against
  real Azure infrastructure). A future Azure implementation should call this
  module's current interface directly rather than resurrect the old one.
