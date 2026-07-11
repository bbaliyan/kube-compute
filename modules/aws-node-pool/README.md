# aws-node-pool

Provisions a fixed-size pool of K3s worker nodes on AWS (ASG + launch template) that joins an
existing `aws-control-plane` cluster via its join-token flow. One pool = one subnet = one availability
zone; AZ-locality workloads (e.g. a SQL client local to its AZ) use one pool per AZ.

## Scope

The module provisions **workers and only what is intrinsic to them** — the launch template, the
ASG, and their IAM role/instance-profile. It **never creates network fabric** and owns **no
security group of its own** in this slice: workers attach only the control plane's
`cluster_security_group_id` (east-west among cluster members) and accept no traffic from outside
the cluster. An ingress-facing SG for workers that serve external traffic is a deliberate gap,
left for whichever later slice wires up an ingress load balancer.

## Fixed vs. elastic

`desired_count` sets `min_size = max_size = desired_capacity` — a **fixed** pool, the safe default
for stateful workloads. An **elastic** pool (`min < max` plus an autoscaler, stateless workloads
only) is a future, opt-in option; this module does not implement it yet.

## Version skew

`k8s_version` (this pool) must not be newer than `control_plane_k8s_version` (the cluster's control
plane) — a kubelet may trail the API server by up to 3 minors, never lead it. A newer pool version
fails `tofu plan` with a clear error instead of silently joining a skewed node.

## Joining the control plane

Three inputs come from the control plane's outputs (wire them via a terragrunt `dependency` block in a
real consumer repo): `registration_address`, `agent_token_ssm_parameter`,
`cluster_security_group_id`. The module's IAM role is scoped to `ssm:GetParameter` on that one
parameter (plus `kms:Decrypt` via the SSM service) — it cannot read any other parameter in the
account. The agent token is fetched at boot; it is never rendered into the launch template's
user_data.

## AZ label

Every worker gets `--node-label topology.kubernetes.io/zone=<az>`, derived from `subnet_id` via a
data lookup — not passed explicitly, since the pool's AZ is intrinsic to which subnet it launches
into. `extra_node_labels` adds any further labels (e.g. a workload-identity label).

## Access

Operator access to workers is via AWS SSM (the IAM role attaches
`AmazonSSMManagedInstanceCore`), the same as `aws-control-plane` — no inbound shell port. IMDSv2 is
enforced on the launch template.

## Inputs

See `variables.tf`. Compute sizing is AWS-native: `instance_type`, `root_volume_size_gb`,
`root_volume_type`. `os_image_ami_id` defaults to the latest Amazon Linux 2023 for the derived
architecture, matching `aws-control-plane`.

## Outputs

`autoscaling_group_name`, `launch_template_id`, `node_provider` (`"aws"`), `availability_zone`,
`worker_iam_role_name`.

## Testing

    cd modules/aws-node-pool
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS, and confirming the agent actually joins, is run by the operator
from a consumer repo.
