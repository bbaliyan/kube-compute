# aws-cluster

One Terraform state for a whole AWS cluster: the control plane from
[`aws-control-plane`](../aws-control-plane/README.md), named workers from
[`aws-static-node`](../aws-static-node/README.md), and autoscaled workers from
[`aws-node-pool`](../aws-node-pool/README.md). Every input `aws-control-plane`
accepts is available here unchanged.

```hcl
module "cluster" {
  source = "path/to/kube-compute/modules/aws-cluster"

  cluster_name          = "example"
  cluster_type          = "dedicated_control_plane"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/24"]
  subnet_names          = ["private-az1", "private-az2"]
  os_image_name         = "almalinux10-*-kube-image-v1.36.2-*"
  instance_type         = "t4g.large"

  static_nodes = {
    platform = { instance_type = "t3a.xlarge", root_volume_size_gb = 40 }
  }
  platform_node_group = "platform"

  autoscaled_nodes = {
    workers = {
      instance_types = ["m7a.large", "m7a.xlarge", "m7a.2xlarge"]
      max_cpu_cores  = 16
      max_memory_gib = 64
    }
  }

  power_schedule = { stop_time = "20:00", timezone = "UTC" }
}
```

## Names

`cluster_name` is the cluster's identity: tags, resource names, the agent token parameter,
and node names such as `cp-example-1` and `platform-example-1`. It has to be unique in the
account and region. Where one cluster design is deployed more than once, put what tells
the copies apart in the name: `app-red`, `app-blue`.

The DNS name is `cluster_name` too, so `cluster_name = "app-red"` and `cluster_domain = "red.example.internal"`
serve the cluster at `app-red.red.example.internal`.

A cluster name may start with a letter or a digit: `app-red` and `7c-demo` both work.

### Your own node names

Where nodes must follow a naming rule of their own, for example to join a Windows
domain, whose computer names are at most 15 characters, pass a template.
`control_plane_node_name_template` names the control-plane nodes, and each `static_nodes`
group takes its own `node_name_template`. In a template, `{zone}` becomes the last letter
of the node's availability zone and `{number}` the node's number as two digits:

```hcl
control_plane_node_name_template = "demo-{zone}-cp{number}"

static_nodes = {
  platform = { node_count = 2, node_name_template = "demo-{zone}-wk{number}" }
}
```

That gives `demo-a-cp01`, `demo-a-wk01` and `demo-a-wk02` in zone a. The name is the node's
hostname, its Kubernetes node name and its Name tag. A template must contain `{number}`, and no
two templates may be the same, so nodes never share a name. A name may be up to 63 characters;
keeping it within a stricter limit, such as Windows' 15, is up to you. `{zone}` comes from the
availability zone's name, so `control_plane_subnets` must be keyed by zone names such as
`eu-west-1a`, not zone IDs. Autoscaled nodes keep the names AWS gives them.

Changing a template changes the user data of the nodes. A running node keeps its old
hostname and Kubernetes node name until it is replaced. See "User data changes".

## Nodes

| Kind | Input | For |
|---|---|---|
| Control plane | `cluster_type`, `instance_type` | RKE2; also workloads unless `dedicated_control_plane` |
| Static | `static_nodes` | Capacity the cluster must always have |
| Autoscaled | `autoscaled_nodes` | Pods that fit nowhere else |

Static and autoscaled nodes launch into the control plane's subnet, so the
cluster stays in one availability zone: an EBS volume cannot cross zones. A
static group can take its own `subnet_id` as a deliberate exception.

`subnet_names` is a list of candidates for that one subnet, not a set to spread across, so
the candidates may sit in different zones. A new cluster goes into the first candidate
with a free address for the control plane and every static node that shares its subnet. A
candidate with some free addresses but too few is skipped, rather than chosen and failing
the apply partway. The choice is kept in state, so the cluster stays in its subnet. No
plan makes the choice again, however full that subnet becomes or however the list changes.
Autoscaled workers are not counted, since they launch later; one that finds the subnet
full fails to join until addresses free up.

To choose again on purpose, replace the stored choice:

```sh
tofu apply -replace='module.<name>.module.control_plane.terraform_data.subnet_choice[0]'
```

If the new choice is a different subnet, the apply replaces every node. You can
also destroy the cluster and apply again.

Every node carries `kube-compute.io/node-group=<key>`: the static group's name, or
the autoscaled role's, whatever the node's size. `node_taints` keeps other pods
off; pods that belong there need a matching toleration.

## Argo CD manifest

The first control-plane node clones the platform ref (`gitops_platform_repo_url` at `gitops_platform_revision`) before RKE2 starts. It takes the Cilium and Argo CD manifests from `bootstrap/rendered/` in the clone. The AMI must hold git. If `gitops_platform_enabled` is false, set `gitops_platform_repo_url`, because the node still reads the Cilium manifest from it. See [`node-bootstrap`](../node-bootstrap/README.md).

After Cilium is Ready, the first server removes the Cilium file from the RKE2 manifests directory, even when GitOps is off. A later server restart then no longer applies it again.

## Platform node

`platform_node_group` names the static group that runs the platform stack:

- its components are pinned to that group;
- it alone takes the security group carrying `ingress_ports`, since Traefik runs there;
- the wildcard DNS record points at it;
- `platform_node_iam_role_name` resolves to its role.

Without it, all of that stays on the control plane.

## Autoscaling

Each `autoscaled_nodes` entry is a role listing the instance types it may
launch. Every type is its own EC2 Auto Scaling group starting at zero, because
cluster-autoscaler requires one shape per group. The platform Application then
runs:

- **cluster-autoscaler**, which adds a node for a pod that fits nowhere else, of the
  size leaving the least capacity idle, and removes unneeded nodes;
- **the AWS cloud controller manager's node lifecycle controller**, which deletes the
  Node object of a terminated instance so its pods and volumes can move. The autoscaler
  never deletes Node objects itself.

Each one authenticates as the node it runs on. The autoscaler runs on the platform node,
the cloud controller manager on the control plane, and the first node back after a stop.
This module gives each role its permissions. Scaling is limited to this cluster's own
groups.


Both find a node's instance through its providerID, so every node of an autoscaled cluster
registers `aws:///<zone>/<instance-id>`. **Adding the first group, or removing the last,
changes the user data of the control plane and static nodes.** A running node keeps its
old registration until it is replaced. Replace those nodes on purpose. See "User data
changes".

### Limits

A role's `max_cpu_cores` and `max_memory_gib` cap the vCPUs and memory its nodes may add
up to, whichever sizes the autoscaler picks. The autoscaler's own `--cores-total` and
`--memory-total` count every node in the cluster. So this module passes every role's caps
plus the control plane and static nodes, as read from AWS. `cluster_autoscaler_limits`
shows the result. A pod that would need more stays Pending.

Those totals are cluster-wide: with several roles, the autoscaler enforces the sum of
their caps. Each Auto Scaling group's maximum is how many of its type fit its role's caps
alone. An instance type larger than its role's caps fails the plan.

## Power schedule

`power_schedule` says when the cluster's nodes run. `days` names the days it runs,
in EventBridge Scheduler's form (`MON-FRI`, `MON,WED,FRI`); it is off on the
rest. Unset, it runs every day.

At `stop_time` on each of those days it stops the control plane and static nodes. At the
same moment it sets every autoscaled group to zero, because an instance in an Auto Scaling
group cannot be stopped. Those schedules sit in the `<cluster_name>-to-zero` schedule
group, one per role and instance type. Nothing is left running to scale the groups back
up. When the cluster is started again, the lifecycle controller removes the old nodes and
the autoscaler adds new ones as pods need them.

Nothing starts the cluster unless `start_time` is set, in which case the
`<cluster_name>-node-start` schedule starts the control plane and static nodes.
When `start_time` is earlier than `stop_time`, that is on the same day. When it is
later, the hours cross midnight and each day's run starts the evening before:

```hcl
power_schedule = {
  days       = "MON-FRI"
  start_time = "22:00"
  stop_time  = "18:00"
  timezone   = "UTC"
}
```

This runs Sunday 22:00 to Monday 18:00, up to Thursday 22:00 to Friday 18:00, and
is off from Friday afternoon to Sunday evening. The stop fires `MON-FRI` and the
start `SUN-THU`. A time zone without daylight saving, such as UTC, keeps those
hours the same all year in every location.

`all_instance_ids` lists the instances Terraform owns individually, also as
`local.all_instance_ids` for files a consumer generates into this directory.

## Graceful shutdown

`graceful_shutdown` is how long kubelet holds up an OS shutdown while it evicts pods. A
node stopped by `power_schedule`, scaled in by the autoscaler or simply terminated then
stops its workloads instead of having them killed with it. `critical_seconds` is the part
of that window reserved for critical pods.

Three settings have to agree, and every node gets all three. They are a kubelet drop-in
carrying the grace period, a `config.yaml.d` fragment pointing kubelet at that drop-in,
and a logind override raising `InhibitDelayMaxSec`. The fragment is needed because
`shutdownGracePeriod` has no command-line flag, so `kubelet-arg` cannot reach it. The
logind override matters just as much: left at its five-second default, logind caps
kubelet's window to five seconds and the eviction never finishes.

Keep the total well under the two minutes a cloud allows an instance before it pulls the
power. Leave room inside it for the longest `terminationGracePeriodSeconds` among the pods
that run here. Null disables the feature.

It is on by default and adds files to every node's user data. A running node gets
them only when it is replaced. See "User data changes".

A spot interruption is only partly covered. The OS shutdown arrives at the end of the
two-minute warning rather than at its start, so this is a backstop. Draining on the
warning itself needs a node termination handler running in the cluster.

## OS updates

`os_auto_updates` has every node install OS updates with `dnf-automatic` daily at 06:00 and 15 minutes after every boot. So nodes stopped overnight by `power_schedule` update when they start. It never reboots: kube-platform's Node OS Updates dashboard shows the nodes whose updates
need one, and rebooting them is left to whoever runs the cluster. RKE2's own packages
are excluded from dnf, so system-upgrade-controller stays the only thing that changes
the Kubernetes version.

It is on by default and changes every node's user data. A running node gets it only
when it is replaced. See "User data changes".

## Volumes on destroy

A destroy deletes each node's root volume with its instance. It deletes no data
volume by itself, including one still attached to a node.

`orphan_volume_cleanup` deletes the cluster's dynamically provisioned EBS volumes once its
nodes are gone. A destroy never deletes a PVC, so the CSI driver is never asked to release
the volume behind it. The volume is left detached and billed. Nothing picks it up later,
so each destroy adds another set.

The sweep matches volumes tagged `ClusterName` with this cluster's name, which the
platform chart is expected to apply. It deletes only volumes that are `available`. It
waits first for any still detaching, since an Auto Scaling group terminates its instances
after Terraform has stopped waiting on it. Whoever runs the destroy needs
`ec2:DescribeVolumes` and `ec2:DeleteVolume`.

Turn it off where a volume is meant to outlive its cluster. A PersistentVolume kept with
`reclaimPolicy: Retain` carries the same tag and would be swept with the rest.

Keep `orphan_volume_cleanup` on to delete data volumes tagged with the cluster's
`ClusterName`. Callers of `aws-control-plane` without `aws-cluster` keep every
data volume on destroy.

## User data changes

Most inputs end up in a node's user data: Helm parameters, names,
`graceful_shutdown`, `os_auto_updates`, and whether the cluster autoscales. A
module upgrade can change it too. cloud-init reads user data only at the first
boot, so a running node never applies a change.

A changed user data does not touch a running control-plane or static node. To apply
it, replace the node on purpose. The addresses are:

- First control-plane node: `module.<name>.module.control_plane.aws_instance.control_plane["0"]`
- Other control-plane nodes: `module.<name>.module.control_plane.aws_instance.control_plane["1"]`
- Static node: `module.<name>.module.static_nodes["<group>"].aws_instance.node["1"]`

> **Warning:** Replacing a single-node cluster loses the cluster.

For a control-plane node on a multi-node cluster, replace one node at a time:

1. If the cluster has one node, stop. Replacing it loses the cluster.
2. Select a node. Replace the additional nodes first, one at a time. Start with key `"1"`.
3. Drain the node: `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`.
4. Delete the Kubernetes node: `kubectl delete node <node>`.
5. Replace the instance: `tofu apply -replace='<address>'`.
6. Verify that the node is `Ready`: `kubectl get nodes`.
7. Verify that every etcd pod is `Running`: `kubectl -n kube-system get pods -l component=etcd`.
8. If another additional node needs the change, go back to step 2.

> **Warning:** Replace the first node last, in its own apply.

9. Do steps 3 to 7 for the first node.

For a static node, drain it, delete the Kubernetes node, replace it, and verify that
it is `Ready`.

Autoscaled nodes are not affected: an Auto Scaling group gives new user data only to
the instances it launches later.

## Testing

    cd modules/aws-cluster
    tofu init -backend=false && tofu test
