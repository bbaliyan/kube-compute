# node-bootstrap

Triggers an Ansible-driven RKE2 install/join for **one node**, given a role
already assigned by the caller (`server-init`, `server-join`, or `worker`).
This module never decides how many nodes exist or which role each gets — that
stays in the provider modules (`aws-control-plane`, `proxmox-control-plane`,
`aws-node-pool`, `proxmox-node-pool`, ...), matching the existing two-layer
split.

Terraform triggers the run via a `null_resource`'s `local-exec` provisioner
invoking `ansible-playbook`, which connects to the node over whichever
transport the caller's `ansible_connection_vars` describe (AWS: SSM; Proxmox:
SSH) — never a new inbound port.

## Scope of this build

This module reproduces `cloud-init`'s RKE2 install/join mechanics: config.yaml
generation for all three roles, the etcd-learner join-race staggering,
systemd unit management, secrets flow, AWS+Proxmox connectivity, OS prep
(RHEL9 `br_netfilter`/`overlay`, sysctls, SELinux package install), CA trust
(`trusted_ca_pem`), registry mirror (`registry_mirror_url`), the Cilium CNI
HelmChart manifest, etcd snapshot configuration (`etcd_snapshot_*`), node
labels (`node_labels`), extra server manifests (`extra_server_manifests`),
and GitOps/Argo CD bootstrap (`gitops_*`, `cert_mode`, `platform_*`,
`extra_tags` — a distinct post-install step, applied via `kubectl` once the
cluster reports Ready, server-init only).

**Deliberately deferred** — present in `cloud-init`'s template but not yet
ported here:

- Kubeconfig publish-to-local-file step (cloud-init's old
  `/var/lib/kube-compute/kubeconfig` — superseded anyway by `kube-kubeconfig`
  fetching `/etc/rancher/rke2/rke2.yaml` directly)

A follow-on ticket adds the minimal connectivity-only user-data each provider
module needs, and cuts the provider modules (`aws-control-plane`,
`proxmox-control-plane`, `aws-node-pool`, `proxmox-node-pool`) over from
calling `cloud-init` to calling this module, in one atomic step — avoiding a
functionality-regression window on `kube-compute` main's working baseline.
Until that lands, `cloud-init` remains the module actually wired into every
provider module; this module is a new, independently validated build.

## Watching progress during a real apply

Terraform/OpenTofu unconditionally suppresses this provisioner's own live
console output ("output suppressed due to sensitive value in config") the
moment any value in this resource's config touches something sensitive
(`CLUSTER_TOKEN` etc.) — a static, config-level decision, not based on what
the command actually prints. The full output still surfaces if the command
*fails* (it's part of the error diagnostic), just not while it's running.

For live progress during a long apply, run `kube-tail` (`kube-devenv`) from a
second terminal — it tails the `bootstrap_log_path` output
(`/tmp/kube-compute-bootstrap-<node_name>.log` on whatever machine runs
`terragrunt apply`) for you, prompting to pick a node the same way
`kube-status`/`kube-shell` do. It's a plain mirror of the same output Ansible
would print anyway — every secret-touching task in the role already sets
`no_log: true`, so nothing new or sensitive lands there that wasn't already
safe to display. (An earlier design considered splitting the secrets and the
Ansible invocation into separate provisioner steps so the apply console
itself could stream live — Terraform's output suppression turned out to be
scoped per-provisioner-block, not per-resource, so this is technically
possible — but doing so needs secrets to cross between the two steps via a
brief on-disk file, a real trade-off against Ticket 03's "secrets never touch
a file" principle. `kube-tail` avoids that trade-off entirely by watching the
existing log file from a separate process instead.)

## Interface notes

- `ansible_playbook_path` mirrors `cloud-init`'s `cloud_init_template`
  escape hatch: overridable, defaults to the bundled AlmaLinux-9-only
  playbook (`ansible/playbook.yml`). No compatibility guarantee for other
  distributions.
- `ansible_connection_vars` is a non-secret map the caller assembles for its
  own provider's transport — this module never branches on provider.
- `cluster_token`/`cluster_agent_token`/`agent_token_fetch_command` are all
  `sensitive = true` and flow to the Ansible run via the `local-exec`
  `environment` block only — never as an extra-var, never in the generated
  inventory. `server-join` receives `cluster_token` the same direct way
  `server-init` does (both get the same freshly-generated cluster secret —
  there's no existing secret store to fetch a *server* token from); only
  `worker` uses the fetch-command pattern, since a worker joins an
  already-existing cluster and can pull its token from the provider's own
  secret store.
