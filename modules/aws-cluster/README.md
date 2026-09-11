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
- **cluster-autoscaler now exists here too**, through `cluster_autoscaler_enabled`
  and the three variables beside it, mirroring `proxmox-cluster`'s own inputs. One
  structural difference: the Proxmox path applies a clusterctl-generated
  `capi-install.yaml` staged onto the VM template at image build time, and the AWS
  image stages nothing of the kind. Cluster API therefore arrives as a platform
  Argo CD Application (`clusterApiEnabled`), and `bootstrap.sh` waits for its CRDs
  instead of installing them. A provider version bump is then a value change in
  `platform-versions/values.yaml`, not an AMI rebuild. See "Cluster API
  autoscaling" below.

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

## Cluster API autoscaling

Off by default. Turning it on creates one `MachineDeployment` per worker group,
each with its own min and max, and switches on kube-platform's `clusterApiEnabled`
and `clusterAutoscalerEnabled` Applications automatically — this module owns the
decision, so the consumer sets one flag rather than three.

```hcl
cluster_autoscaler_enabled = true

cluster_autoscaler_worker_groups = {
  platform = {
    instance_type     = "t4g.large"
    min_size          = 1
    max_size          = 3
    attach_ingress_sg = true
  }
  reserved = {
    instance_type = "r5a.large"
    max_size      = 1
    node_labels   = { workload = "reserved" }
    node_taints   = ["workload=reserved:NoSchedule"]
  }
}
```

A group is the unit the autoscaler scales, so split by anything a pod can select
on: a CPU architecture, a taint, a shape. Each group resolves its own image from
`os_image_name` and the architecture AWS reports for its instance type, so one
image name serves an arm64 and an x86_64 group in the same cluster.

It composes with `static_nodes` rather than replacing it, but prefer a group. A
named instance is only necessary where something outside the cluster depends on
which machine it is.

**A group starting at zero needs its shape advertised.** Nothing reports a group's
capacity while it has no nodes, so the `MachineDeployment` also carries the vCPU,
memory, labels and taints as `capacity.cluster-autoscaler.kubernetes.io`
annotations. They are read from AWS rather than restated by the caller. Without
them the autoscaler cannot tell whether a Pending pod would fit, and never scales
the group off zero — which is exactly the case for a tainted group.

**Ingress on an autoscaled node.** `attach_ingress_sg` gives a group the security
group carrying the cluster's external ports, and labels its nodes
`kube-compute.io/ingress=true`. Traefik is a DaemonSet behind ServiceLB, so those
nodes serve ingress the moment they join. Terraform cannot then own the wildcard
DNS record, because it never sees those instances: set
`manage_wildcard_dns_record = false` and external-dns publishes them instead. The
same flag switches on kube-platform's `externalDnsEnabled`, so the record cannot
end up owned by nobody.

**`cluster_domain` is required.** Autoscaled workers join through
`api.<cluster_name>.<cluster_domain>`, an explicit Route53 record the control-plane
module creates. A specific name beats a wildcard, so it keeps resolving to the
control plane even where external-dns has filled the wildcard with worker
addresses. It cannot be the control plane's own IP: the
`MachineDeployment` bundle is written into that instance's cloud-init, so reading
an output derived from the instance is a dependency cycle. A precondition fails
the apply rather than baking a null address into every worker's Secret.

**An autoscaled cluster's payload has to stay small.** The CAPI bundle carries one
worker cloud-init per group inside the genesis node's own user data, and EC2 allows
16384 decoded bytes for everything that node boots with. That budget is why the
bootstrap program is baked into the image rather than rendered per node: it used to
appear once for the control plane and once more in every group. Set
`trusted_ca_in_image` when the image also bakes the corporate CA, which travelled
the same way. With both out of the payload, a two-group cluster renders 12471 bytes
and a group costs roughly 1 KB instead of 6. `modules/aws-control-plane/README.md`
has the numbers and the reasoning.

**The controller authenticates as the control-plane node.** There is no IRSA on a
self-managed cluster, so the AWS provider uses the node's instance profile. The
policy letting it call `RunInstances`, `TerminateInstances`, `CreateTags` and
`PassRole` for the worker profile belongs on `node_iam_role_name`, attached by the
consumer repo. Without it the provider logs an authorization failure per reconcile
and creates nothing.

**The spend ceiling is every group's `max_size` added together.** Nothing in
Kubernetes understands money, so the enforcing limit is a node count. Worst-case
monthly spend is each group's maximum times its own instance's hourly price times
the hours the cluster actually runs — which for a cluster that stops nightly is roughly 300, not
730. The `cluster_autoscaler_worst_case_node_count` output exists so a consumer can
derive the count from a budget rather than typing it.

**Known unverified.** The `AWSCluster` is marked externally managed so the
provider does not try to own the VPC, which also means nothing ever sets its
`status.ready`, and CAPI's machine controller gates on
`Cluster.status.infrastructureReady`. This is the same open question
`proxmox-cluster` records against its own bundle, unresolved there too. If no
worker instance ever appears and the `AWSMachine` reports no error, that is the
first thing to check. The full list is in the header of
`templates/cluster-autoscaler-workers.yaml.tftpl`.
