# aws-control-plane

Provisions the AWS control plane for an RKE2 cluster — its control-plane node(s) plus the
cluster-wide resources — consuming `node-bootstrap` for per-cluster identity, join tokens, and
GitOps bootstrap. A control plane with `control_plane_count = 1` is a complete single-node
cluster.

## Boot flow: pre-baked AMI + lean cloud-init, no live connection

This module runs **no live Ansible** at `apply` time. It renders `node-bootstrap`'s
`#cloud-config` payload (node identity, join tokens, registries/CA, GitOps Application
manifests — see `modules/node-bootstrap/README.md`) and attaches it as `user_data_base64`,
combined via a cloud-init MIME multipart document with a small AWS-only shell-script part that
enables the SSM Agent (SSM stays this module's operator-access path — break-glass shell,
verb-scripts — independent of bootstrap). Nothing in this module connects to the node, waits on
it, or observes it converge; `apply` returns as soon as the instance and its user-data exist.

The heavy half of RKE2 bootstrap (RKE2 binaries, SELinux policy, kernel modules, the genesis
Cilium/Argo CD manifests) is expected to already be baked into the AMI, via `kube-image`'s
`packer/aws/` template (see the `kube-image` repo). **`os_image_ami_id` is opt-in**: pass a
kube-image-baked AMI id to get a fully working cluster. The default fallback — the latest stock
AlmaLinux 10 AMI, when `os_image_ami_id` is left null — has **no RKE2 baked in**, so a node
booted from it will not join a cluster; it exists only so `effective_ami_id`/the AMI lookup keep
resolving to something for plan-time testing and as a base image for your own bake. This mirrors
`proxmox-control-plane`'s already-established `proxmox_template_vm_id` convention.

## Scope

The module provisions the **node and only what is intrinsic to it** — the EC2 instance, its
own security group, its IAM role/instance-profile, and (optionally) a DNS record. It **never
creates network fabric** (VPC, subnet, internet gateway, NAT, route tables); you plug in
existing networking, or it falls back to the account's default VPC.

## Topology

- **`control_plane_count`** — `1` (default), `3`, or `5`. `2` and `4` are rejected (no
  fault-tolerance benefit, split-brain risk). `3`/`5` place one control-plane node per
  availability zone (requires `control_plane_subnets` — a map of AZ -> subnet id — spanning at
  least 3 distinct AZs; fewer than 3 fails plan with a clear error) behind an internal NLB on
  6443; `registration_address` becomes the NLB's DNS name. The first control-plane node's
  bootstrap probes that address at boot: reachable → join the existing quorum; unreachable →
  initialize (so replacing the first node is a safe rejoin, never a second cluster
  initialization — RKE2 has no `--cluster-init` flag at all; the first server is simply the
  one whose config omits a `server:` join address).
- **`cluster_type`** — `all_in_one` (default; control-plane node stays schedulable) or
  `dedicated_control_plane` (control-plane node is tainted `CriticalAddonsOnly=true:NoExecute`;
  intended for use once node pools exist). The taint is derived from this explicit intent, never
  from node counts — node pools are separate Terraform state this module cannot see.
- **Datastore** — always embedded etcd (RKE2 has no SQLite option — etcd is its only
  supported datastore), including for `control_plane_count = 1`, for one consistent
  datastore and uniform snapshots across topologies.

## Networking

Three ways to specify the subnet (pick one):

- **`subnet_id`** — pass the literal subnet ID to launch into your own or corp subnet.
- **`subnet_name`** — pass the Name tag; the module resolves the ID via a data lookup. Pair with
  `vpc_name` to scope the search when the tag is not globally unique.
- **Neither** — the module falls back to a subnet in the account's **default VPC** (data lookup;
  it never *creates* a VPC). Accounts whose default VPC was deleted must pass a subnet.

## DNS (optional)

DNS is a convenience, not a hard dependency:

- Set `cluster_domain` to get a named FQDN (`api.<cluster>.<domain>`) and a wildcard
  (`*.<cluster>.<domain>`). Omit it and the node is reachable by IP only.
- Additionally set `hosted_zone_id` to have the module create the wildcard A record in that
  Route53 zone.
- If you don't pass `hosted_zone_id`, the module creates **no** DNS record — register the
  `wildcard_dns_name` output at the `cluster_ip` in whatever DNS you run (Route53, a local
  resolver, RFC2136, external-dns, or an `sslip.io`-style fallback).

## Access

Zero inbound beyond `ingress_ports` (default 80/443/6443) from `allowed_ingress_cidrs`; no SSH.
IMDSv2 is enforced. Operator access to the node is via AWS SSM (the IAM role attaches
`AmazonSSMManagedInstanceCore`) — there is no inbound shell port.

## Join flow (workers and, later, additional control-plane nodes)

This module no longer generates the join tokens. They come from this cluster's
`aws-cluster-facts` unit, which applies first and fast, so a node pool no longer has to wait on
the control plane's full apply for them: `cluster_token` (the **server token**, used for both the
genesis `server-init` and every additional `server-join` node) and `cluster_agent_token` (the
**agent token**, mirrored by `aws-cluster-facts` into an SSM `SecureString` that workers fetch via
their own instance IAM role). Both are required, sensitive inputs here. Workers receive only the
agent token — never the server token — so a compromised worker cannot rejoin as a
control-plane/etcd member. `k8s_version` is required for the same reason: both this module and
`aws-node-pool` consume the one resolved value from `aws-cluster-facts`, so version skew between
them is prevented by construction.

Two security groups carry the cluster's east-west traffic. The self-referencing, every-member one
is created by `aws-cluster-facts` and passed in as `cluster_security_group_id` (this module
attaches its own instances to it, exactly as `aws-node-pool` does — it does not create it, and
does not re-export it). The second, created here, is control-plane-only and scopes etcd
(2379-2380) so workers can never reach it. `registration_address` is what a joining node's
`--server` flag targets — for `control_plane_count = 1` this is simply the control-plane node's
private IP; it is still this module's own output, the one join value `aws-node-pool` continues to
source from the control plane rather than from `aws-cluster-facts`.

`k8s_version` was previously required here so this module and `aws-node-pool` would consume the
same resolved value by construction. It is still accepted for wiring continuity, but no longer
threaded anywhere — see "Boot flow" above for why (the kube-image AMI bakes the version instead).

## HA control plane (`control_plane_count` > 1)

`control_plane_subnets` (a map of availability zone -> subnet id) is required once
`control_plane_count > 1` — the module does not auto-discover multi-AZ subnets for the HA case
the way it falls back to the default VPC for a single node. The map's keys ARE the AZs (no lookup
needed), so a caller cannot accidentally supply two subnets in the same AZ. Pass at least 3
entries spanning at least 3 distinct AZs; fewer fails plan explicitly rather than silently
forming a weaker quorum.

Once `control_plane_count > 1`, the single `subnet_id`/`subnet_name` above is not used for
control-plane placement or networking — this is by design, not merely cosmetic: the module's own
VPC (used for its security groups and the NLB target group) is derived from
`control_plane_subnets` itself in that mode, so there is no path by which `subnet_id`/`subnet_name`
could disagree with where the instances actually launch.

The genesis node (the same `server-init` node used for `control_plane_count = 1`) is unchanged in
shape. Additional control-plane nodes (`server-join`) bootstrap concurrently with it and join via
the NLB, retrying against the registration endpoint the same way a worker retries its join target
until genesis is up; node-bootstrap's own staggered, self-healing retry handles the one genuine
etcd constraint (one non-voting learner at a time) among the joining siblings. Argo/platform GitOps
inputs are only ever passed to the genesis node's `node-bootstrap` call, so platform bootstrap
manifests are never applied — and never race — on more than one server.

## Container Network Interface (CNI)

`cni` is `null` by default, which resolves to `"cilium"` regardless of topology. `"default"`
(Canal/flannel+Calico) remains selectable but is not viable on AlmaLinux 10, this project's
only supported OS: its kernel dropped the legacy `br_netfilter`/`xt_conntrack`/`xt_comment`
modules that flannel and Felix's iptables dataplane both hard-require — confirmed via a real
apply, not a theoretical concern. It's kept as an escape hatch for a consumer-supplied
playbook targeting a different OS. On a single-node cluster (`control_plane_count = 1`), the
Cilium operator's replica count is set to `1` (rather than the chart default of `2`) so the
second replica doesn't sit permanently `Pending` with nowhere to schedule. The cluster security
group's self-referencing all-protocol rule (created by `aws-cluster-facts`) already covers every
CNI's control-plane and pod-to-pod traffic; switching `cni` never requires a security-group
change, and no per-CNI ingress rules are created by this module.

## Registration endpoint modes (`endpoint_mode`)

Only relevant once `control_plane_count > 1` — a single control-plane node has no registration
endpoint at all.

- **`loadbalancer`** (default) — an internal NLB across all control-plane nodes on 6443.
- **`dns`** — one Route53 A record per control-plane node under a shared name
  (`cp.<cluster_name>.<cluster_domain>`), multivalue-answer routing, each backed by a
  `CLOUDWATCH_METRIC` health check on that instance's own EC2 status-check alarm (Route53's public
  health-checker fleet can't reach a private VPC IP directly, so the alarm is the bridge). Requires
  `cluster_domain` and a resolvable hosted zone (`hosted_zone_id` or `hosted_zone_name`). Cheaper
  than an NLB; failover is TTL-bound (the record's `ttl = 10`), not instant.
- **`static`** — creates no load balancer or DNS record at all; `static_registration_address` is
  used verbatim. For a consumer that already runs its own front end.

## Inputs

See `variables.tf`. Environment-specific values are inputs — none are baked in. Compute sizing
is AWS-native: `instance_type` (bundles vCPU+memory), `root_volume_size_gb`, `root_volume_type`.
`os_image_ami_id` defaults to the latest stock AlmaLinux 10 for the derived architecture (no RKE2
baked in — see "Boot flow" above); pass a kube-image-baked AMI id to get a working cluster. Three
inputs come from this cluster's `aws-cluster-facts` unit and are required: `cluster_token`,
`cluster_agent_token`, and `cluster_security_group_id` (wire them via a terragrunt `dependency`
block in a real consumer repo) — see "Join flow" above. `k8s_version` is still accepted (kept for
`aws-cluster-facts` wiring continuity) but currently unused by this module — node-bootstrap has no
`k8s_version` input anymore, since the kube-image AMI bakes the installed RKE2 version at build
time; see `k8s_version`'s own description in `variables.tf`.

## Outputs

Standardized across provider modules: `instance_id`, `cluster_ip`, `cluster_fqdn` (null when
IP-only), `node_provider` (`"aws"`), `node_control_ref`. Plus `wildcard_dns_name` (for
self-service DNS), `aws_region`, `node_arch`, `effective_ami_id`, `vpc_id`, `subnet_id`,
`node_iam_role_name`. Join flow: `registration_address` (a node's private IP for
`control_plane_count = 1`; otherwise shaped by `endpoint_mode` — see "Registration endpoint modes"
above) and `control_plane_node_refs` (every control-plane node once `control_plane_count > 1`, not
just the first) — see "Join flow" and "HA control plane" above. The agent-token SSM parameter name
and the cluster security group id are **not** outputs of this module; `aws-node-pool` reads both
from `aws-cluster-facts` directly.

## Out of scope (lives in the consumer repo)

Team-specific operational policy is **not** in this module — e.g. a nightly stop schedule. Add
an `aws_scheduler_schedule` in your own config referencing the `instance_id` output if you want
one.

## Testing

    cd modules/aws-control-plane
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS is run by the operator from a consumer repo.
