# node-bootstrap

Renders a `#cloud-config` document for **one node**, given a role already
assigned by the caller (`server-init`, `server-join`, or `worker`). This
module never decides how many nodes exist or which role each gets — that
stays in the provider modules.

## What this module does — and does not do

This module executes nothing and creates no resources of its own. There is no
`null_resource`, no `local-exec`, no connection of any kind to the node, no
Ansible, and no `data.external` Helm render at plan time. `cloud_init_user_data`
is a complete cloud-init document (hostname, RKE2
`config.yaml`/`registries.yaml`/trusted-CA/manifest payloads as base64
`write_files`, and a `runcmd` that invokes an on-node bootstrap script). The
caller attaches the `user_data` output to its VM; this module has no resource
to `depends_on`.

## User data

`user_data` is the final user data of the node. It is `cloud_init_user_data`
alone, or a MIME multipart/mixed document when shell-script parts run first:

- `ssm_agent_enabled = true` adds a part that starts the AWS SSM Agent. The AWS
  modules set it.
- Each entry of `boot_scripts` becomes a part. The script sees `CLUSTER_NAME`,
  `NODE_ROLE` (`control-plane` or `worker`) and `NODE_NAME`.

cloud-init runs the shell-script parts before the cloud-config's `runcmd`.
With no parts, `user_data` is the plain cloud-config.

The heavy half of bootstrap — OS prep, RKE2 binaries, SELinux policy, kernel
modules, the guest agent, **and the genesis Cilium manifest** — is
expected to already be baked into the image the caller boots the VM from (a
template built by kube-images). Argo CD is not baked; the first server downloads it
(see below). This module only renders the per-cluster
identity, secrets, and join logic that can't be baked into a shared image.
`modules/proxmox-control-plane` and `modules/proxmox-node-pool` are the only
callers currently wired for this — both accept an optional
`proxmox_template_vm_id` to full-clone a pre-baked image, alongside their
older stock-cloud-image paths.

## Cilium is baked, Argo CD is downloaded

The node image bakes the Cilium manifest at `/opt/kube-compute/manifests/cilium.yaml`.
A node with `cni: cilium` is not Ready without it. The `render_cilium` local only
decides whether `bootstrap.sh` applies it.

The image does not bake Argo CD. kube-platform publishes one manifest per release,
`argocd-bootstrap.yaml`, with its sha256. It is about 2 MB, too big for the cloud-init
payload (Proxmox allows 1 MiB). So the first server downloads it at first boot:

1. `bootstrap.sh` downloads `argocd_manifest_url`. It retries a few times.
2. It compares the file with `argocd_manifest_sha256`. If they differ, the boot fails.
3. It applies the file with server-side apply.
4. It waits for the Argo CD workloads to roll out.

Each failure stops the boot and is written to `/var/log/kube-compute-bootstrap.log`.
The node needs a route to the URL at first boot.

`argocd_manifest_url` and `argocd_manifest_sha256` have no default. They are required
on the first server while a platform or workloads Application is enabled, and the plan
fails without them. The hash must be 64 lowercase hex characters. Take both from a
kube-platform release, for example
`https://github.com/bbaliyan/kube-platform/releases/download/<tag>/argocd-bootstrap.yaml`.

### Upgrade order

This change is breaking. The `node.env` contract moves from 2 to 4. Contract 3 was never
released. Contract 4 adds `REJOIN_PROBE_ADDRESSES`, the list of addresses a first server probes
for a live cluster before it starts etcd (the `rejoin_probe_addresses` input).

1. Rebuild the node image without the baked Argo CD manifest. The new image carries
   the new `bootstrap.sh`.
2. Move the module to the new major version and set the two inputs.

The first server removes the baked `cilium.yaml` from the RKE2 manifests directory after
Cilium is Ready. RKE2 applies every file in that directory again on each start. Without
the removal, a restart would put the older baked Cilium back after the platform upgraded
it. Removing the file does not remove Cilium from the cluster. If Cilium is not Ready
within about 6 minutes, the file stays and the log shows a warning. The first server removes the file even when GitOps is off, so a later server restart no longer applies the baked Cilium again.

An image with the old module, or the new module with the old image, fails on the
contract check at the first line of `bootstrap.sh`. Existing clusters do not change
until a node is replaced.

## Watching progress during a real apply

Terraform/OpenTofu returns as soon as the cloud-init payload is attached to
the VM — it has no way to know when (or whether) the node actually joins the
cluster, since nothing in this module executes anything. That all happens
asynchronously on the node, after `apply` has already returned. The node
writes its own progress to `/var/log/kube-compute-bootstrap.log`; that log
is the only place to watch bootstrap progress. There is no Terraform-visible
signal, no provisioner output, and no `bootstrap_log_path`-style output.

## The program is in the image; this module sends it values

`bootstrap.sh` is not rendered here and does not travel in the payload. It lives at
`files/bootstrap.sh`, the node image bakes it at `/opt/kube-compute/bootstrap.sh`,
and this module writes the two files it reads:

- **`node.env`** (0644) — configuration. Every key is always defined, empty where a
  role does not use it, so the program runs under `set -u`.
- **`secrets.env`** (0600) — the join tokens and the TSIG secret, unchanged.

Plus one fragment, `rke2-config-static.yaml`, holding everything in `config.yaml`
knowable before the node boots: labels, taints, extra SANs, the server flags,
kubelet's resolv-conf pointer. Which blocks a role gets is decided here; the program
appends the fragment to the few lines only the node itself can produce (its own IP,
the fetched agent token, the rejoin-probe result).

**Why.** The program is almost entirely static, and a genesis node used to carry it
once for itself and again inside every worker group's cloud-init, against EC2's
16384-byte user-data limit. Shipping values instead of code keeps the payload small on
every platform, with no per-platform side channel.

**The contract.** `node_env_contract` in `main.tf` and `BOOTSTRAP_CONTRACT` in
`files/bootstrap.sh` are the two halves of one number. Bump both together when a key
is added, removed, or changes meaning. Three things enforce it:

- An output precondition here fails the plan if the two disagree in this repo.
- A test asserts the program references every key `node.env` defines.
- The program itself refuses to run against a `node.env` written for another
  contract, so a stale image fails on its first line instead of half-configuring a
  node.

An image newer than the module needs no check: an older module ships its own
rendered copy of the program in `write_files`, which overwrites the baked one. The
failing direction is a module newer than the image, and `runcmd` names it — it tests
the program exists before running it and says what to rebuild.

## Genesis-apply manifests

`genesis_apply_manifests` is an ordered list of `{path, content}` entries. This module
writes each one verbatim under `/opt/kube-compute/manifests/` with `write_files`.
`bootstrap.sh` then runs `kubectl apply -f` on each one in order. This module does not
interpret `content` at all.

The input is genesis-only (`server-init` only). It does not depend on
`gitops_platform_enabled`. No module in this repo sets it today.

## Workloads repo parameters on the `platform` Application

If `gitops_workloads_repo_url` is set, the `platform` Application gets three more Helm parameters:

- `workloadsRepoURL`, from `gitops_workloads_repo_url`.
- `workloadsRevision`, from `gitops_workloads_revision`.
- `workloadsPath`, from `gitops_workloads_path`.

If `gitops_workloads_repo_url` is not set, the Application has none of them and renders as before. kube-platform treats a missing parameter as empty.

The module writes the `platform` Application at first boot. An existing cluster gets these parameters only when its node is rebuilt. See "A change to the user data of a running node".

## Upgrade note: the Argo CD Applications are built with `yamlencode`

The module now renders the `platform` and `workloads` Applications with `yamlencode`. The decoded Applications are the same, but the text is not. So every genesis node that writes the `platform` Application gets new user data, with or without a workloads repo. See "A change to the user data of a running node" for what that does to the node.

## A change to the user data of a running node

This module renders the user data. Its callers decide what a change does to a node that already runs. Every input of this module is in the user data, so a change to any of them is a user data change. So is a module upgrade that changes the render.

cloud-init reads the user data only at the first boot. A running node never applies a change to it.

The control-plane modules (`aws-control-plane`, `proxmox-control-plane`) and `aws-static-node` treat a change the same way on both providers: the node keeps running. On AWS, the instance keeps the user data it booted with. On Proxmox, the snippet on storage gets the new content, but the VM is not replaced.

To apply a change to a node, replace that node on purpose with `tofu apply -replace='<address>'`.

`aws-node-pool` (an Auto Scaling group) and `proxmox-node-pool` work the same way for running nodes. An Auto Scaling group gives new user data only to the instances it launches later.

### Replace a node on purpose

> **Warning:** Replacing a single-node cluster loses the cluster. Replace one control-plane node at a time, and the first node last, in its own apply.

1. Find the address of the node with `tofu state list`. Examples: `module.<name>.module.control_plane.aws_instance.control_plane["1"]`, `module.<name>.module.static_nodes["<group>"].aws_instance.node["1"]`, `module.<name>.module.control_plane.proxmox_virtual_environment_vm.control_plane["1"]`.
2. Drain the node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
3. Delete the Kubernetes node: `kubectl delete node <node>`.
4. Run `tofu apply -replace='<address>'`.
5. Read the plan. Verify that it replaces only the node you named.
6. Confirm the apply.
7. Verify that the node is `Ready` and, for a control-plane node, that every etcd pod is `Running`.

On Proxmox, also replace the firewall of an additional control-plane VM. See "Rolling to a new template" in the `proxmox-control-plane` README.

## `set_hostname` (for shared, byte-identical cloud-init payloads)

Every caller gets `set_hostname = true` (the default): `hostname`/`fqdn` are
written into cloud-config from `node_name`, required because RKE2/kubelet
registers the node by OS hostname. `set_hostname = false` omits both keys
entirely — the only reason to do this is when the exact same rendered
`cloud_init_user_data` is shared across multiple VMs that cannot each get
their own render (e.g. every instance of an AWS Auto Scaling group, via one
launch template). The VM platform's own per-instance
metadata is relied on instead to supply a unique hostname — **this specific assumption is
unverified against real hardware**, flagged explicitly as a first
real-cluster check for any `set_hostname = false` caller.

## `aws_provider_id`

Registers the node with providerID `aws:///<zone>/<instance-id>` and labels it
`node.kubernetes.io/instance-type`, written as an RKE2 `config.yaml.d` drop-in from
instance metadata before the bootstrap program starts RKE2. cluster-autoscaler and
the AWS cloud controller manager find a node's instance through the providerID. The
label is otherwise set by a cloud controller manager's node controller, which RKE2's
is not here (`disable-cloud-controller`) and kube-platform's AWS one does not run.
Off by default, since turning it on changes the payload of existing nodes. See
"A change to the user data of a running node".

## Resources reserved for the node

Every node reserves CPU and memory for kubelet, containerd, RKE2 and the OS, so pods
can never take all of it. Without a reservation a crowded node doesn't evict pods: it
reclaims memory until containerd stops answering kubelet and the node goes NotReady.
The node sizes the reservation from its own memory and cores and writes it as an RKE2
`config.yaml.d` drop-in before RKE2 starts. Memory follows EKS's per-pod formula, capped
by GKE's older tiers as GKE and AKS now do, since kubelet and containerd grow with the
number of pods rather than with the node's memory:

| | Reserved |
|---|---|
| `kube-reserved` memory | 11 MiB per pod plus 255 MiB at RKE2's default of 110 pods (1465 MiB), or 25% of the first 4 GiB, 20% of the next 4, 10% of the next 8, 6% up to 128 GiB and 2% above, whichever is smaller |
| `kube-reserved` CPU | 6% of the first core, 1% of the second, 0.5% of the next two, 0.25% above |
| `system-reserved` | 100m CPU, 256 MiB |
| `eviction-hard` | `memory.available<100Mi`, plus kubelet's own disk and inode defaults, which the flag would otherwise drop |

An 8 GiB node, for example, keeps about 5.8 GiB for pods and a 16 GiB node about 13.7 GiB.

The control plane runs as static pods, so server nodes give them requests through
`control-plane-resource-requests` (kube-apiserver 1024Mi, etcd 512Mi,
kube-controller-manager 256Mi, kube-scheduler 128Mi) and the scheduler counts their
memory instead of the reservation having to cover it.

## Graceful shutdown

`graceful_shutdown` gives kubelet a window to evict pods when the OS is shutting
down, so a node that is stopped or terminated stops its workloads instead of having
them killed with it. Three files carry it, all written before RKE2 starts:

| File | Why |
|---|---|
| `/etc/rancher/rke2/kubelet.conf.d/10-graceful-shutdown.conf` | `shutdownGracePeriod` and `shutdownGracePeriodCriticalPods` |
| `/etc/rancher/rke2/config.yaml.d/30-graceful-shutdown.yaml` | `kubelet-arg` cannot set either — they have no command-line flag — so kubelet is given `config-dir` and reads the drop-in above |
| `/etc/systemd/logind.conf.d/99-kube-compute-inhibit.conf` | `InhibitDelayMaxSec`, five seconds by default, is the longest logind lets kubelet hold the shutdown. Left alone it silently caps the grace period to five seconds |

`runcmd` restarts `systemd-logind` so the last of those applies to the node's first
shutdown, not just later ones. The total must stay under whatever the platform allows
an instance before it cuts the power — about two minutes on AWS — and must leave room
for the longest `terminationGracePeriodSeconds` among the pods that land here. Null
disables all of it.

## OS updates

`os_auto_updates` installs `dnf-automatic` and `yum-utils` once the node has joined,
and enables `dnf-automatic-install.timer`, which installs updates daily and never
reboots. The timer runs at 06:00 and also 15 minutes after every boot, so a node that
is powered off at 06:00, such as one on a power schedule, still updates. `rke2-server`, `rke2-agent` and `rke2-common` are excluded in `dnf.conf`, so
RKE2 only moves through system-upgrade-controller; `rke2-selinux` still updates.
`needs-restarting -r` from `yum-utils` is what kube-platform's os-updates collector
reads to report that a node needs a reboot. False leaves the node's packages as baked.

## Interface notes

- `ansible_playbook_path`, `invocation_mode`, `ansible_connection_vars`,
  `on_node_bundle`, `on_node_secret_env`, `node_provider`, `bootstrap_id`,
  `cilium_version`, `argocd_version`, and `cilium_operator_replicas` are all
  gone. There is no playbook, no `null_resource`, no on-node bundle, no
  provider branching, and no Helm render in this module — the two version
  variables had no effect once kube-images took over the render (both are
  baked into the template, resolved from kube-platform's
  `platform-versions.yaml` at build time), and `cilium_operator_replicas` had
  nowhere left to reach once the render was no longer per-cluster
  (kube-platform's own `cilium-app.yaml` hardcodes `replicas: 1` and
  overwrites any genesis-time value on Argo CD's first `selfHeal` anyway).
- `cni` defaults to `"cilium"` (eBPF dataplane, no iptables/ipset/xtables
  dependency — the only variant verified against AlmaLinux 10). When
  `cni = "cilium"` on a genesis node, the module has `bootstrap.sh` apply the
  Cilium manifest kube-images already baked onto the template, and sets
  `disable: [rke2-cilium]` in `config.yaml` so RKE2's own built-in HelmChart
  install of Cilium never runs alongside it. `"default"` remains selectable
  only as an escape hatch for a consumer-supplied image/template that ships a
  different CNI out of the box.
- `cluster_token`/`cluster_agent_token`/`agent_token_fetch_command`/
  `trusted_ca_pem`/`tsig_key_secret` are all `sensitive = true` and flow only
  into the cloud-init payload's base64-encoded `write_files` (a 0600
  `/opt/kube-compute/secrets.env`, sourced by the bootstrap script) — never
  as plaintext Terraform state elsewhere, never over any inbound connection.
  `server-join` receives `cluster_token` the same direct way `server-init`
  does; only `worker` uses the fetch-command pattern, since a worker joins an
  already-existing cluster and pulls its token from the provider's own
  secret store instead.
- `modules/aws-control-plane` and `modules/aws-node-pool` are also cut over to
  this interface: both call this module with no
  `node_provider`/`ansible_playbook_path`/`ansible_connection_vars` and attach
  this module's `user_data` output via AWS's own `base64gzip(...)`
  convention, with `ssm_agent_enabled = true` so the MIME multipart document
  carries the SSM Agent script (see User data above). `aws-node-pool`'s ASG
  launch template calls this module with `set_hostname = false` since every
  pool member shares one rendered payload — same pattern as
  the same.
  `modules/azure-control-plane`/`modules/azure-node-pool` no longer exist as
  working code — reduced to placeholders (their prior implementation called
  this module's pre-cutover interface and was never validated against real
  Azure infrastructure). A future Azure implementation should call this
  module's current interface directly rather than resurrect the old one.
