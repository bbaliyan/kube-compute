# node-bootstrap

Renders a `#cloud-config` document for **one node**, given a role already
assigned by the caller (`server-init`, `server-join`, or `worker`). This
module never decides how many nodes exist or which role each gets — that
stays in the provider modules.

## What this module does — and does not do

This module executes nothing and creates no resources of its own, other than
two `external` data sources (`data.external.cilium_manifest`,
`data.external.argocd_manifest`) that run `helm template` at plan time. There
is no `null_resource`, no `local-exec`, no connection of any kind to the node,
and no Ansible. Its single meaningful output is `cloud_init_user_data` — a
complete cloud-init document (hostname, RKE2 `config.yaml`/`registries.yaml`/
trusted-CA/manifest payloads as base64 `write_files`, and a `runcmd` that
invokes an on-node bootstrap script). The caller is responsible for attaching
that output to its VM as user-data; this module has no resource to
`depends_on`.

The heavy half of bootstrap — OS prep, RKE2 binaries, SELinux policy, kernel
modules, the guest agent — is expected to already be baked into the image the
caller boots the VM from (a "kube-image" template). This module only renders
the per-cluster identity, per-cluster secrets, and join logic that can never
be baked into a shared image. `modules/proxmox-control-plane` and
`modules/proxmox-node-pool` are the only callers currently wired for this —
both accept an optional `proxmox_template_vm_id` to full-clone a pre-baked
image, alongside their older stock-cloud-image paths.

## `helm template` runs at plan time, on your machine

When a genesis node (`node_role = "server-init"`) is in the plan with
`cni = "cilium"`, or with a GitOps repo configured (`gitops_platform_enabled`
or `gitops_workloads_repo_url`), this module shells out to `helm template` via
`scripts/helm-render.py` to pre-render the Cilium and/or Argo CD manifests
that get embedded in the cloud-init payload. This happens on whatever machine
runs `tofu plan` — not on the node, not at apply time. That machine needs the
`helm` binary, `python3`, and network access to `helm.cilium.io` and
`argoproj.github.io` whenever such a node is being planned. `tofu test` never
hits this path: every test mocks the `external` provider.

## Watching progress during a real apply

Terraform/OpenTofu returns as soon as the cloud-init payload is attached to
the VM — it has no way to know when (or whether) the node actually joins the
cluster, because nothing in this module executes anything. All of that now
happens asynchronously on the node itself, after `apply` has already
returned. The node writes its own progress to
`/var/log/kube-compute-bootstrap.log`; that log is the only place to watch
bootstrap progress. There is no Terraform-visible signal, no provisioner
output, and no `bootstrap_log_path`-style output to depend on.

## Interface notes

- `ansible_playbook_path`, `invocation_mode`, `ansible_connection_vars`,
  `on_node_bundle`, `on_node_secret_env`, `node_provider`, and `bootstrap_id`
  are all gone. There is no playbook, no `null_resource`, no on-node bundle,
  and no provider branching in this module.
- `cni` defaults to `"cilium"` (eBPF dataplane, no iptables/ipset/xtables
  dependency — the only variant verified against AlmaLinux 10). When
  `cni = "cilium"` on a genesis node, the module renders the Cilium chart via
  `helm template` at plan time, writes the manifest into the cloud-init
  payload, and sets `disable: [rke2-cilium]` in `config.yaml` so RKE2's own
  built-in HelmChart install of Cilium never runs alongside it. `"default"`
  remains selectable only as an escape hatch for a consumer-supplied
  image/template that ships a different CNI out of the box.
- `cilium_operator_replicas` defaults to `null` (the Cilium chart's own
  default of `2`, with pod anti-affinity). The calling control-plane module
  passes `1` when `control_plane_count = 1` — otherwise the second replica
  has nowhere to schedule and sits permanently `Pending` on a genuinely
  single-node cluster.
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
