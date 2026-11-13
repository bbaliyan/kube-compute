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
caller attaches the `cloud_init_user_data` output to its VM; this module has no resource
to `depends_on`.

## User data

`cloud_init_user_data` is the final user data of the node. It is a plain `#cloud-config` document.

The image must already hold OS prep, the RKE2 binaries, the SELinux policy, the kernel
modules, the guest agent and these tools: git, curl, getent, ip, awk, systemctl
and update-ca-trust. Build it with kube-images. The image holds neither Cilium
nor Argo CD: the first server reads both from the platform ref (see below).
This module renders only the per-cluster identity, secrets and join logic.
Every provider module calls it: `aws-control-plane`, `aws-static-node`, `aws-node-pool`,
`proxmox-control-plane` and `proxmox-node-pool`.

## Cilium and Argo CD come from the platform ref

The first server needs two manifests that are too big for the cloud-init payload:
Cilium and Argo CD. It reads both from the platform repo, so one value picks the
version of both: `gitops_platform_repo_url` at `gitops_platform_revision`. This is the
same ref that the platform Application syncs.

On the first server, before RKE2 starts, the boot program does these steps:

1. It checks that the image has the tools listed above. If tools are missing, it names all of them in one message and stops.
2. It clones the platform ref into `/run/platform-ref`. It tries 5 times, 5 seconds apart.
   - For a branch or a tag, it runs `git clone --depth 1 --branch`.
   - For a 40-digit hex commit, it runs `git clone --filter=blob:none --no-checkout` and then `git checkout`.
3. If `bootstrap/rendered/cilium.yaml` or `bootstrap/rendered/argocd.yaml` is missing, it stops with one line that names the repo, the ref and the path.
4. It reads `k8sVersion` from `platform/platform-versions/values.yaml`. If the minor version of the RKE2 in the image is newer, it stops. A newer patch of the same minor version is fine.
5. On the first server, it copies `cilium.yaml` into the RKE2 manifests directory.
6. After the node is Ready and CoreDNS is up, it applies `argocd.yaml` with server-side apply.
7. It waits for the Argo CD workloads to roll out.

Each failure stops the boot and is written to `/var/log/kube-compute-bootstrap.log`.
The node needs a route to the repo at first boot, and the repo must be readable without
credentials. A joining server or a worker clones nothing.

A joining server also compares its image's RKE2 with the version that the API server
reports at `/version`. It stops if the minor version of the image is newer. It skips the comparison when the
API server does not answer. A worker does not compare.

If `gitops_platform_enabled` is false, the module does not fall back to the pinned repo.
Set `gitops_platform_repo_url` when the first server needs Cilium or Argo CD. If it is not
set, the plan fails with a message that names the input. The pinned default
(`kube-platform` at `main`) applies only while the platform Application is enabled.

### Upgrade order

A first server probes `REJOIN_PROBE_ADDRESSES` for a live cluster before it starts etcd
(the `rejoin_probe_addresses` input). If it finds one, it becomes a joining server. It
skips Cilium, the extra server manifests, Argo CD and the Applications.

1. Rebuild the node image with git, and without a baked Cilium or Argo CD manifest.
2. Move the module to the new version.

The first server removes the copied `cilium.yaml` from the RKE2 manifests directory after
Cilium is Ready. RKE2 applies every file in that directory again on each start. Without
the removal, a restart would put the boot Cilium back after the platform upgraded it.
Removing the file does not remove Cilium from the cluster. If Cilium is not Ready within
about 6 minutes, the file stays and the log shows a warning. The first server removes the
file even when GitOps is off.

Existing clusters do not change until a node is replaced.

## Watching progress

Terraform/OpenTofu returns as soon as the cloud-init payload is attached to
the VM — it has no way to know when (or whether) the node actually joins the
cluster, since nothing in this module executes anything. That all happens
asynchronously on the node, after `apply` has already returned. The node
writes its own progress to `/var/log/kube-compute-bootstrap.log`; that log
is the only place to watch bootstrap progress. There is no Terraform-visible
signal, no provisioner output, and no `bootstrap_log_path`-style output.

## The program travels in user data

The boot program is a list of step files in `files/steps/`. The module lists them in
`boot_step_catalog`, each with the condition that selects it. It joins the steps that
apply to the node's role and writes the result to `/opt/kube-compute/bootstrap.sh`
(0755) as one `write_files` entry. `runcmd` runs it. A step that does not apply to the
role is never in the file:

- Core steps depend on the role. A server runs `node-config-server`, the start and
  wait steps for servers and the skew check. An agent runs `node-config-agent`,
  `start-agent` and `wait-ready-agent`.
- Genesis steps (`platform-clone`, `genesis-cilium-manifest`, `genesis-cilium-handoff`,
  `genesis-argocd`, `genesis-extra-manifests`) are in the
  program only on the first server, and only when the feature is on.
- Provider steps are not here. The provider modules pass them in `provider_steps` and
  `provider_files`: DNS self-registration and the iSCSI initiator name on Proxmox, SSM
  Agent and the provider ID on AWS.

The `boot_steps` output lists every step in the order it runs. The provider modules
assert the exact list in their tests, so a step of one provider cannot reach the other.

The module removes the comment lines first, to save space. A line whose first non-blank
character is `#` is dropped, except the shebang. A step must use no heredoc, because a
body line that starts with `#` would be dropped. A test fails if a step has one.

The module also writes the files the program reads:

- **`/etc/rancher/rke2/config.yaml`** (0600) — the RKE2 config known at plan time: the
  join server and tokens, labels, taints, extra SANs, the server flags and kubelet's
  resolv-conf pointer. cloud-init writes it. The program adds only what the node alone
  knows, as the drop-in `config.yaml.d/20-node.yaml`: its own IP, the server that the
  rejoin probe found and, on an agent, the fetched token.
- **`node.env`** (0644) — configuration for the program. Every key is always defined,
  empty where a role does not use it, so the program runs under `set -u`.
- **`secrets.env`** (0600), on an agent only — the agent token fetch command. The program
  deletes it when the boot succeeds. If the boot fails, it stays for diagnosis.

The trusted CA is a `write_files` entry and a `runcmd` entry (`update-ca-trust extract`).
There is no registry mirror check at boot.

EC2 limits user data to 16384 bytes after gzip. A test renders a heavy AWS genesis
node and asserts it stays at least 1024 bytes under that limit.

## Workloads repo parameters on the `platform` Application

If `gitops_workloads_repo_url` is set, the `platform` Application gets three more Helm parameters:

- `workloadsRepoURL`, from `gitops_workloads_repo_url`.
- `workloadsRevision`, from `gitops_workloads_revision`.
- `workloadsPath`, from `gitops_workloads_path`.

If `gitops_workloads_repo_url` is not set, the Application has none of them and renders as before. kube-platform treats a missing parameter as empty.

The module writes the `platform` Application at first boot. An existing cluster gets these parameters only when its node is rebuilt. See "A change to the user data of a running node".

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
launch template). The platform's per-instance metadata then supplies a unique hostname.

## DNS search domains

Kubelet copies the search domains of the node's `/etc/resolv.conf` into every pod. Pods use `ndots:5`, so a name such as `github.com` tries each search suffix first. If a search domain has a wildcard record, the name resolves to that wildcard and not to the real host.

If you set `dns_servers`, the module writes a kubelet `resolv.conf` with those servers and no `search` line. Every pod on the node then skips the search domains. If you do not set it, kubelet uses the node's own `/etc/resolv.conf`.

## Provider steps

`provider_steps` and `provider_files` carry what only one provider needs. This module
holds no AWS or Proxmox logic. `aws-boot-steps` builds the AWS steps: SSM Agent and,
with `aws_provider_id`, the providerID and the instance-type label. cluster-autoscaler
and the AWS cloud controller manager find a node's instance through the providerID.
`proxmox-boot-steps` builds the Proxmox steps: the iSCSI initiator name, and DNS
self-registration with `nsupdate` on the first server. A step is a name and cloud-init
`runcmd` commands. A provider file is a `write_files` entry that the commands read.
The provider steps run first. A failed `runcmd` command does not stop the later ones.

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

- The CNI is always Cilium. On a
  genesis node, the boot program applies the Cilium manifest from the platform ref, and
  `config.yaml` sets `disable: [rke2-cilium]` so RKE2's own Cilium chart never runs.
- `cluster_token`, `cluster_agent_token`, `agent_token_fetch_command` and `trusted_ca_pem`
  are `sensitive = true`. They reach the node only in the base64 `write_files` of the
  payload, such as the 0600 `/etc/rancher/rke2/config.yaml`.
  `server-join` receives `cluster_token` the same way `server-init` does. Only `worker`
  runs `agent_token_fetch_command`, to read the agent token from the provider's secret store.
- `aws-node-pool` sets `set_hostname = false`, because every member of a pool shares one
  rendered payload.
