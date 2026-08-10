# aws-node-pool

Provisions a fixed-size pool of RKE2 worker nodes on AWS — an Auto Scaling Group held at a fixed
size, not elastic — that joins an existing `aws-control-plane` cluster via its join-token flow.
One pool = one subnet = one availability zone; AZ-locality workloads (e.g. a SQL client local to
its AZ) use one pool per AZ.

## Boot flow: pre-baked AMI + lean cloud-init, no live connection

This module runs **no live Ansible** at `apply` time. Every worker in the pool boots from the same
launch template, whose `user_data` is `node-bootstrap`'s `#cloud-config` payload (join tokens,
registries/CA — see `modules/node-bootstrap/README.md`) MIME-multipart-combined with a small
AWS-only shell-script part that enables the SSM Agent (SSM stays this pool's operator-access path,
independent of bootstrap). Because the ASG creates every instance from the same launch template,
Terraform never sees individual pool members or assigns them distinct node names — `node-bootstrap`
is called with `set_hostname = false`, relying on cloud-init's EC2 datasource to assign each
instance its own naturally-unique hostname, the same behavior this pool relied on before the ASG
was originally swapped out. Nothing in this module connects to a worker, waits on it, or observes
it converge.

**`os_image_ami_id` is opt-in**, same convention as `aws-control-plane`: pass a kube-image-baked
AMI id (with RKE2 already installed) to get workers that actually join. The default fallback — the
latest stock AlmaLinux 10 AMI — has no RKE2 baked in and will not join a cluster; it exists only
so the AMI lookup resolves to something for plan-time testing and as a base image for your own
bake.

## Scope

The module provisions **workers and only what is intrinsic to them** — the launch template, the
ASG, their IAM role/instance-profile. It **never creates network fabric** and owns **no security
group of its own** in this slice: workers attach only `aws-cluster-facts`'s
`cluster_security_group_id` (east-west among cluster members) and accept no traffic from outside
the cluster. An ingress-facing SG for workers that serve external traffic is a deliberate gap,
left for whichever later slice wires up an ingress load balancer.

## Fixed-size ASG, no scaling policies

`desired_count` sets `min_size = max_size = desired_capacity` on the ASG — fixed, not elastic; the
safe default for stateful workloads, and deliberately conservative pending a chosen autoscaler
(kube-image-design Ticket 07's locked shape). The primitive still buys self-healing (the ASG
replaces a terminated instance from the same launch template) and rolling launch-template updates
for free, with nothing here reacting to load. Scale by changing `desired_count`. Selecting/wiring
an actual autoscaler to drive `min_size`/`max_size` for real is out of scope for this module.

## Joining the control plane

`agent_token_ssm_parameter` and `cluster_security_group_id` come from this cluster's
`aws-cluster-facts` outputs; `registration_address` still comes from the control plane's own
output (wire all three via terragrunt `dependency` blocks in a real consumer repo). The module's
IAM role is scoped to `ssm:GetParameter` on that one parameter (plus `kms:Decrypt` via the SSM
service) — it cannot read any other parameter in the account. The agent token is fetched on the
node at join time (node-bootstrap's `agent_token_fetch_command` runs the SSM `get-parameter`
command there); it is never rendered into user_data or Terraform state.

## AZ label

Every worker gets `--node-label topology.kubernetes.io/zone=<az>`, derived from `subnet_id` via a
data lookup — not passed explicitly, since the pool's AZ is intrinsic to which subnet it launches
into. `extra_node_labels` adds any further labels (e.g. a workload-identity label).

## Access

Operator access to workers is via AWS SSM (the IAM role attaches
`AmazonSSMManagedInstanceCore`), the same as `aws-control-plane` — no inbound shell port. IMDSv2 is
enforced on every instance. Because pool members are ASG-managed, not individually named Terraform
resources, verb-scripts discover them via the `autoscaling_group_name` output (e.g. `aws
autoscaling describe-auto-scaling-groups` or `aws ec2 describe-instances --filters
tag:aws:autoscaling:groupName=<name>`), not a Terraform-visible instance-id list.

## Inputs

See `variables.tf`. Compute sizing is AWS-native: `instance_type`, `root_volume_size_gb`,
`root_volume_type`. `os_image_ami_id` defaults to the latest stock AlmaLinux 10 for the derived
architecture (no RKE2 baked in — see "Boot flow" above); pass a kube-image-baked AMI id to get
workers that actually join.

## Outputs

`autoscaling_group_name`, `launch_template_id`, `node_provider` (`"aws"`), `availability_zone`,
`worker_iam_role_name`.

## Testing

    cd modules/aws-node-pool
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS, and confirming the agent actually joins, is run by the operator
from a consumer repo.
