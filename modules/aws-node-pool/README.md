# aws-node-pool

A group of RKE2 worker nodes that cluster-autoscaler scales between zero and
`max_size`, as an EC2 Auto Scaling group joining an existing `aws-control-plane`
cluster. `aws-cluster` creates one per `autoscaled_nodes` entry.

```hcl
module "workers" {
  source = "../aws-node-pool"

  cluster_name              = "cluster-x"
  group_name                = "workers-large"
  aws_region                = "eu-west-1"
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  cluster_security_group_id = module.control_plane.cluster_security_group_id
  subnet_id                 = module.control_plane.subnet_id

  instance_type = "t3a.large"
  max_size      = 2
}
```

## How cluster-autoscaler uses it

- **Discovery.** The group is tagged `k8s.io/cluster-autoscaler/enabled` and
  `k8s.io/cluster-autoscaler/<cluster_name>`.
- **Scale from zero.** With no nodes to inspect, the autoscaler reads the
  instance type from the launch template, and the labels and taints from
  `k8s.io/cluster-autoscaler/node-template/*` tags on the group.
- **Matching nodes to instances.** Every node registers
  `aws:///<zone>/<instance-id>` as its providerID.
- **Desired capacity.** The autoscaler owns it, so Terraform never sets it.

The autoscaler terminates instances but does not delete their Node objects.
kube-platform's AWS cloud controller manager does, which is what lets a pod bound
to a vanished node, and its volume, move.

## Nodes

Every node boots the same launch template, so EC2 names the host.
`topology.kubernetes.io/zone` and `kube-compute.io/node-group` are always set.
`node_taints` keeps other pods off the group, but only pods with a matching
toleration can then land there.

The group has its own IAM role with SSM access, the EBS CSI driver policy, and
read access to the one agent-token parameter. Nodes take only the cluster's
east-west security group; ingress runs on the platform node.

Pass the control plane's `subnet_id`: an EBS volume cannot cross availability
zones.

## Testing

    cd modules/aws-node-pool
    tofu init -backend=false && tofu test
