# spine-aws

Provisions the AWS control plane for a K3s cluster — its control-plane node(s) plus the
cluster-wide resources — consuming `node-bootstrap` for the K3s cloud-init. A spine with
`control_plane_count = 1` is a complete single-node cluster.

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
  initialize (so replacing the first node is a safe rejoin, never a second `--cluster-init`).
- **`cluster_type`** — `all_in_one` (default; control-plane node stays schedulable) or
  `dedicated_control_plane` (control-plane node is tainted `CriticalAddonsOnly=true:NoExecute`;
  intended for use once worker pools exist). The taint is derived from this explicit intent, never
  from node counts — worker pools are separate Terraform state this module cannot see.
- **Datastore** — always embedded etcd (`k3s server --cluster-init`), including for
  `control_plane_count = 1`, for one consistent datastore and uniform snapshots across topologies.

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

The spine pre-generates two tokens (`random_password`, both sensitive) so a worker pool can join
in the same apply pass it's created in: a **server token** (unused until the HA control-plane
slice wires up additional control-plane nodes) and a separate **agent token**, mirrored into an
SSM `SecureString` (`agent_token_ssm_parameter` output). Workers receive only the agent token —
never the server token — so a compromised worker cannot rejoin as a control-plane/etcd member.

Two security groups carry this: `cluster_security_group_id` is self-referencing and shared by
every cluster member (control-plane and worker pools) for east-west traffic; a second,
control-plane-only security group scopes etcd (2379-2380) so workers can never reach it.
`registration_address` is what a joining node's `--server` flag targets — for `control_plane_count
= 1` this is simply the control-plane node's private IP.

## HA control plane (`control_plane_count` > 1)

`control_plane_subnets` (a map of availability zone -> subnet id) is required once
`control_plane_count > 1` — the module does not auto-discover multi-AZ subnets for the HA case
the way it falls back to the default VPC for a single node. The map's keys ARE the AZs (no lookup
needed), so a caller cannot accidentally supply two subnets in the same AZ. Pass at least 3
entries spanning at least 3 distinct AZs; fewer fails plan explicitly rather than silently
forming a weaker quorum.

The genesis node (the same `server-init` node used for `control_plane_count = 1`) is unchanged in
shape. Additional control-plane nodes (`server-join`) `depends_on` it and join via the NLB;
Argo/platform GitOps inputs are only ever passed to the genesis node's `node-bootstrap` call, so
platform bootstrap manifests are never applied — and never race — on more than one server.

**Out of scope for this build:** etcd snapshot durability and the `dns`/`static` registration
endpoint alternatives (a later issue); `wildcard_dns_name`/`cluster_ip` continue to reference only
the first control-plane node — routing user-facing ingress traffic across an HA control plane (or,
better, to a worker pool) isn't handled here.

## Inputs

See `variables.tf`. Environment-specific values are inputs — none are baked in. Compute sizing
is AWS-native: `instance_type` (bundles vCPU+memory), `root_volume_size_gb`, `root_volume_type`.
`os_image_ami_id` defaults to the latest Amazon Linux 2023 for the derived architecture.

## Outputs

Standardized across provider modules: `instance_id`, `cluster_ip`, `cluster_fqdn` (null when
IP-only), `node_provider` (`"aws"`), `bootstrap_status_ref`. Plus `wildcard_dns_name` (for
self-service DNS), `aws_region`, `node_arch`, `effective_ami_id`, `vpc_id`, `subnet_id`,
`node_iam_role_name`. Join flow: `registration_address` (a node's private IP for
`control_plane_count = 1`, the internal NLB's DNS name otherwise), `agent_token_ssm_parameter`,
`cluster_security_group_id`, `control_plane_node_refs` (every control-plane node once
`control_plane_count > 1`, not just the first) — see "Join flow" and "HA control plane" above.

## Out of scope (lives in the consumer repo)

Team-specific operational policy is **not** in this module — e.g. a nightly stop schedule. Add
an `aws_scheduler_schedule` in your own config referencing the `instance_id` output if you want
one.

## Testing

    cd modules/spine-aws
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS is run by the operator from a consumer repo.
