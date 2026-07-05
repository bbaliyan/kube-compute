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
  fault-tolerance benefit, split-brain risk). Only `1` is provisioned by this build: `3` and `5`
  pass validation but fail plan with a clear error, pending the multi-AZ control-plane slice that
  wires them up.
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

## Inputs

See `variables.tf`. Environment-specific values are inputs — none are baked in. Compute sizing
is AWS-native: `instance_type` (bundles vCPU+memory), `root_volume_size_gb`, `root_volume_type`.
`os_image_ami_id` defaults to the latest Amazon Linux 2023 for the derived architecture.

## Outputs

Standardized across provider modules: `instance_id`, `cluster_ip`, `cluster_fqdn` (null when
IP-only), `node_provider` (`"aws"`), `bootstrap_status_ref`. Plus `wildcard_dns_name` (for
self-service DNS), `aws_region`, `node_arch`, `effective_ami_id`, `vpc_id`, `subnet_id`.

## Out of scope (lives in the consumer repo)

Team-specific operational policy is **not** in this module — e.g. a nightly stop schedule. Add
an `aws_scheduler_schedule` in your own config referencing the `instance_id` output if you want
one.

## Testing

    cd modules/spine-aws
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS is run by the operator from a consumer repo.
