# aws-node-pool

Provisions a fixed-size pool of RKE2 worker nodes on AWS (discrete EC2 instances) that joins an
existing `aws-control-plane` cluster via its join-token flow. One pool = one subnet = one availability
zone; AZ-locality workloads (e.g. a SQL client local to its AZ) use one pool per AZ.

Each worker is bootstrapped by the shared `node-bootstrap` module over SSM (Ansible running on the
operator, connecting via `amazon.aws.aws_ssm` — no inbound port), the same path `aws-control-plane`
uses. Because the instances are discrete (not an ASG), each gets a stable node name
(`<cluster>-worker-<index>`).

## Scope

The module provisions **workers and only what is intrinsic to them** — the EC2 instances, their
IAM role/instance-profile, and the S3 staging bucket the SSM Ansible transport requires. It
**never creates network fabric** and owns **no
security group of its own** in this slice: workers attach only `aws-cluster-facts`'s
`cluster_security_group_id` (east-west among cluster members) and accept no traffic from outside
the cluster. An ingress-facing SG for workers that serve external traffic is a deliberate gap,
left for whichever later slice wires up an ingress load balancer.

## Fixed pool, no autoscaling

`desired_count` creates exactly that many discrete instances — a **fixed** pool, the safe default
for stateful workloads. There is deliberately no autoscaling or auto-healing: scale by changing
`desired_count`; replace a bad worker by tainting/recreating its instance. (Elastic pools were
considered and left out — see the design notes in the control repo.)

## Version skew

`k8s_version` is expected to match the same `aws-cluster-facts` output the caller passes to
`aws-control-plane` for this cluster, preventing skew by construction rather than by a runtime
check comparing two independently-supplied values.

## Joining the control plane

`agent_token_ssm_parameter` and `cluster_security_group_id` come from this cluster's
`aws-cluster-facts` outputs; `registration_address` still comes from the control plane's own
output (wire all three via terragrunt `dependency` blocks in a real consumer repo). The module's
IAM role is scoped to `ssm:GetParameter` on that one parameter (plus `kms:Decrypt` via the SSM
service) — it cannot read any other parameter in the account. The agent token is fetched on the
node at join time (node-bootstrap runs the SSM `get-parameter` command there); it is never
rendered into user_data or Terraform state.

## AZ label

Every worker gets `--node-label topology.kubernetes.io/zone=<az>`, derived from `subnet_id` via a
data lookup — not passed explicitly, since the pool's AZ is intrinsic to which subnet it launches
into. `extra_node_labels` adds any further labels (e.g. a workload-identity label).

## Access

Operator access to workers is via AWS SSM (the IAM role attaches
`AmazonSSMManagedInstanceCore`), the same as `aws-control-plane` — no inbound shell port. IMDSv2 is
enforced on every instance.

## Inputs

See `variables.tf`. Compute sizing is AWS-native: `instance_type`, `root_volume_size_gb`,
`root_volume_type`. `os_image_ami_id` defaults to the latest AlmaLinux 10 for the derived
architecture, matching `aws-control-plane`.

## Outputs

`instance_ids`, `private_ips`, `node_provider` (`"aws"`), `availability_zone`,
`worker_iam_role_name`.

## Testing

    cd modules/aws-node-pool
    tofu init -backend=false && tofu test   # offline — mock_provider "aws", no credentials

Real `plan`/`apply` against AWS, and confirming the agent actually joins, is run by the operator
from a consumer repo.
