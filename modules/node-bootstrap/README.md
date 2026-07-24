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

This module currently reproduces only the **core RKE2 install/join
mechanics** validated by this project's Ansible-bootstrap map (config.yaml
generation for all three roles, the etcd-learner join-race staggering,
systemd unit management, secrets flow, and AWS+Proxmox connectivity).

**Deliberately deferred** — present in `cloud-init`'s template but not yet
ported here, and not yet wired into this module's variable interface:

- OS prep (RHEL9 `br_netfilter`/`overlay` modules, sysctls, SELinux package
  install) and CA-trust (`trusted_ca_pem`)
- Registry mirror (`registry_mirror_url`)
- Cilium CNI HelmChart manifest (this module's `cni` variable still sets the
  `cni:`/`disable-kube-proxy:` config.yaml flags, but does not deploy the
  Cilium HelmChart itself)
- etcd snapshot configuration (`etcd_snapshot_*`)
- GitOps/Argo CD bootstrap (`gitops_*`, `cert_mode`, `platform_*`,
  `extra_tags`)
- Node labels (`node_labels`) and extra server manifests
  (`extra_server_manifests`)
- Kubeconfig publish-to-local-file step (cloud-init's old
  `/var/lib/kube-compute/kubeconfig` — superseded anyway by `kube-kubeconfig`
  fetching `/etc/rancher/rke2/rke2.yaml` directly)

A follow-on ticket ports the remaining variables into this module's Ansible
role **and** cuts the provider modules (`aws-control-plane`,
`proxmox-control-plane`, `aws-node-pool`, `proxmox-node-pool`) over from
calling `cloud-init` to calling this module, in one atomic step — avoiding a
functionality-regression window on `kube-compute` main's working baseline.
Until that lands, `cloud-init` remains the module actually wired into every
provider module; this module is a new, independently validated build.

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
