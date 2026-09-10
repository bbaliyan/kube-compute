# aws-cluster

A thin wrapper that composes [`aws-control-plane`](../aws-control-plane/README.md),
[`aws-static-node`](../aws-static-node/README.md) and
[`aws-node-pool`](../aws-node-pool/README.md) into a single Terraform state,
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
- **No cluster-autoscaler.** Neither worker path here is elastic. `aws-node-pool`
  provisions a fixed-size ASG (`min_size = max_size = desired_capacity`);
  `aws-static-node` provisions named instances that nothing resizes at all. The
  Proxmox equivalent drives Cluster API through a CAPI install manifest staged onto
  the VM template by `kube-image`, and the AWS Packer template does not stage one,
  so the mechanism the Proxmox path uses has no producer on this side. A Cluster
  API-driven autoscaler for AWS is a real gap, and this is the module to revisit —
  the install would want to come from the platform GitOps repo rather than a baked
  manifest, so that a provider version bump does not mean rebuilding an AMI.

## Inputs

Every input `aws-control-plane` accepts is available unchanged — same name, type,
default, and validation — at this module's own top level. See
[`aws-control-plane`'s README](../aws-control-plane/README.md) and its
`variables.tf` for the full list and field-by-field semantics; this module does not
re-document them.

### static_nodes

`static_nodes` is a map of **named worker node groups** keyed by group name (e.g.
`"platform"`). Each key becomes one `aws-static-node` instance; `node_count` inside
an entry decides how many machines that group has. This module supplies
`cluster_name`, `aws_region`, `registration_address`,
`agent_token_ssm_parameter`, the security groups and (by default) the subnet from
its own inputs and `module.control_plane`'s outputs.

`subnet_id` defaults to the control plane's own resolved subnet, so a group lands
in the control plane's availability zone without anyone naming a subnet per group.
That matters because an EBS volume cannot cross zones: a worker in the wrong one
cannot mount the data it was created for. Set `subnet_id` only for a deliberate
exception.

`attach_ingress_sg` is off by default and should be on for exactly the group that
runs the ingress controller. The security group it adds carries this cluster's
externally reachable `ingress_ports`; moving the ingress pods to a group without
it leaves those ports answering on a node that no longer serves them.

**Prefer `static_nodes` over `node_pools` on a cluster that stops overnight.** An
autoscaling group treats a stopped member as unhealthy and replaces it, so a stop
schedule cannot target one. See
[`aws-static-node`'s README](../aws-static-node/README.md) for the full comparison.

### all_instance_ids and local.all_instance_ids

The `all_instance_ids` output lists every instance Terraform owns individually —
the control-plane node(s) plus every static node's. It is also available as
`local.all_instance_ids` inside the module, which is the form a consumer needs when
it generates an extra `.tf` file into this module's directory (terragrunt's
`generate` block does exactly that for a nightly stop schedule): generated code can
reference the module's locals and module calls, but not its outputs.

Feed a stop schedule from this rather than from `instance_id` alone. A schedule
given only the genesis instance stops the control plane at 20:00 and leaves the
workers running until morning, which inverts the saving it exists for.

### node_pools

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

## Usage: control plane plus named worker nodes

```hcl
module "cluster" {
  source = "path/to/kube-compute/modules/aws-cluster"

  cluster_name          = "example"
  cluster_type          = "dedicated_control_plane"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/24"]
  subnet_names          = ["private-az1", "private-az2"]

  # One value covers both architectures: each node group filters the lookup on the
  # architecture AWS reports for its own instance type.
  os_image_name = "almalinux10-*-kube-image-v1.36.2-*"
  instance_type = "t4g.medium" # control plane

  static_nodes = {
    platform = {
      instance_type       = "t4g.large"
      root_volume_size_gb = 40
      attach_ingress_sg   = true # this group runs the ingress controller
      node_labels         = { "workload" = "platform" }
    }
    dedicated = {
      instance_type       = "r5a.large"
      root_volume_size_gb = 40
      node_taints         = ["dedicated=true:NoSchedule"]
      node_labels         = { "workload" = "reserved" }
    }
  }
}
```

`cluster_type = "dedicated_control_plane"` taints the control-plane node with
`CriticalAddonsOnly=true:NoExecute`, which is what pushes the platform workloads
onto the `platform` group. Set it only once a group exists to receive them —
tainting a single-node cluster leaves nothing anywhere to run.
