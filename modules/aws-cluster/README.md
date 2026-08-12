# aws-cluster

A thin wrapper that composes [`aws-control-plane`](../aws-control-plane/README.md)
and [`aws-node-pool`](../aws-node-pool/README.md) into a single Terraform state,
mirroring [`proxmox-cluster`](../proxmox-cluster/README.md)'s shape and conventions
for operators who want one Terragrunt directory per cluster. It changes nothing
about either composed module internally — it only calls them from one place.

## Single state, single lock

Same tradeoff as `proxmox-cluster`: this module puts the control plane and every
worker pool in **one Terraform state with one lock**. That buys a single
`terragrunt apply` per cluster, at the cost of no longer being able to apply the
control plane and a node pool concurrently from separate terminals. Stay on the
split `aws-control-plane` + `aws-node-pool` layout if that concurrency matters to
you.

## What this module does NOT carry, unlike proxmox-cluster

`proxmox-cluster` also composes `node-os-patch` (an SSH-based OS-upgrade
orchestrator) and an optional CAPI/CAPMOX cluster-autoscaler bundle. Neither
exists here, and neither is a missing feature this module forgot — both are
genuinely inapplicable to AWS today:

- **No `node-os-patch`.** That module is plain SSH, no Ansible — `node-os-patch`'s
  own README calls it "Proxmox-only today." AWS's whole design here has no inbound
  SSH at all (this project's own no-SSH posture, see kube-compute's top-level
  design constraints); `aws-control-plane` exposes no `ssh_user`/
  `ssh_private_key_file` outputs for `node-os-patch` to consume even if you wanted
  to force the wiring. More fundamentally, `aws-node-pool`'s workers are a fixed-size
  ASG — Terraform never sees individual pool members (they're created directly from
  the launch template), so there is no `worker_node_refs`-shaped output for
  `node-os-patch` to iterate over in the first place. An SSM-based patch
  orchestrator for AWS is a real gap, not yet built.
- **No cluster-autoscaler.** `aws-node-pool` provisions a fixed-size ASG
  (`min_size = max_size = desired_capacity`) with no CAPI/cluster-autoscaler
  integration — see `kube-image`'s AWS Packer template, which for the same reason
  doesn't stage a CAPI/CAPMOX install manifest the way the Proxmox one does. If AWS
  ever gets a Cluster API-driven (or ASG-native scaling-policy-driven) autoscaler
  path, this is the module to revisit.

## Inputs

Every input `aws-control-plane` accepts is available unchanged — same name, type,
default, and validation — at this module's own top level. See
[`aws-control-plane`'s README](../aws-control-plane/README.md) and its
`variables.tf` for the full list and field-by-field semantics; this module does not
re-document them.

One additional input, `node_pools`, is a map of worker pools keyed by pool name
(e.g. `"pool-a"`). Each entry's fields mirror `aws-node-pool`'s own `variables.tf`
exactly, minus `cluster_name`, `aws_region`, `registration_address`,
`agent_token_ssm_parameter`, and `cluster_security_group_id` — this module supplies
all five automatically from its own inputs and from `module.control_plane`'s
outputs, so don't (and can't) set them per pool. An empty `node_pools` map (the
default) creates no worker pools — a control-plane-only cluster, identical in shape
to applying `aws-control-plane` alone.

Unlike `proxmox-cluster`, there is no `dns` provider to wire in — AWS's optional DNS
registration goes through Route53 (`hosted_zone_name`/`hosted_zone_id`) via the
`aws` provider you already configure for everything else in this module.

## Usage: control-plane only, no worker pools

```hcl
module "cluster" {
  source = "path/to/kube-compute/modules/aws-cluster"

  cluster_name          = "example"
  aws_region             = "eu-west-1"
  allowed_ingress_cidrs   = ["10.0.0.0/24"]
  os_image_ami_id         = "ami-0123456789abcdef0" # kube-image's AWS Packer build
}
```

This is equivalent to today's split `control-plane/` unit alone — `node_pools`
defaults to `{}`, so no `aws-node-pool` instances are created.

## Usage: control plane plus a worker pool

```hcl
module "cluster" {
  source = "path/to/kube-compute/modules/aws-cluster"

  cluster_name          = "example"
  cluster_type          = "dedicated_control_plane"
  aws_region             = "eu-west-1"
  allowed_ingress_cidrs   = ["10.0.0.0/24"]
  os_image_ami_id         = "ami-0123456789abcdef0"
  subnet_id               = "subnet-0123456789abcdef0"

  node_pools = {
    pool-a = {
      subnet_id       = "subnet-0123456789abcdef0"
      instance_type   = "m7g.large"
      os_image_ami_id = "ami-0123456789abcdef0"
      desired_count   = 2
    }
  }
}
```

Each key in `node_pools` becomes one `aws-node-pool` instance (one ASG), wired to
this cluster's `cluster_name`/`aws_region`/`registration_address`/
`agent_token_ssm_parameter`/`cluster_security_group_id` automatically. Add more
entries for more pools (e.g. `pool-b` in a different AZ/subnet) — the map has no
fixed size. `aws-node-pool` pools are AZ-pinned by design (one pool = one subnet =
one AZ), same reasoning as `aws-node-pool`'s own README.

## Existing standalone modules remain fully supported

`aws-control-plane` and `aws-node-pool` are unchanged and continue to work exactly
as before, applied as separate Terragrunt units with a `dependency` block carrying
`agent_token_ssm_parameter`/`cluster_security_group_id`/`registration_address`
between them. `aws-cluster` is an additional option for consumers who want a single
directory/state per cluster — it does not deprecate, replace, or require migrating
the split layout.
