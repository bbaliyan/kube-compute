# State-migration check

This check shows what an upgrade does to a cluster that already exists.
It applies a released `aws-cluster` to an AWS emulator, then plans this branch on the same state.
A good upgrade plan has only moves.

## How it works

1. `seed/` creates what an account has before the first cluster: a named VPC and subnet, a private hosted zone and an AMI.
2. The released module (`SM_OLD_REF`, default `v0.9.0`) is cloned from the registry mirror.
3. This branch is built into the same layout with `scripts/release-split.sh`.
4. For each case, both trees get `root/emulator.tf` and the case inputs, as Terragrunt would add them.
5. The released tree is applied. The branch tree is planned on that state.
6. `changes.jq` lists each move, update, create, delete and replace.
7. The check fails on an update, create, delete or replace that `allowed/<case>.txt` does not list. Each case lists its own changes, so a regression in one shape fails that case.

## Cases

| Case | Shape |
|---|---|
| `single-ids` | One `all_in_one` node. The subnet is passed by ID (`subnet_id`) |
| `single-names` | As `single-ids`. The VPC and the subnet belong to someone else and are found by name (`vpc_name`, `subnet_names`) |
| `multi-ids`, `multi-names` | A dedicated control plane, a static node group and an autoscaled node group, with the same two network inputs |
| `arm` | A dedicated control plane on `m7g.large` (arm64), static groups on arm64 and x86_64, autoscaled pools on arm64 and x86_64. Subnet by ID |
| `ha` | Three control-plane nodes in three zones, with `endpoint_mode = "static"` |
| `names-zone` | One node. The subnet comes from `subnet_names` and the node name holds `{zone}`, so the zone must be known at plan time |
| `names-full` | Two candidates in one VPC. The first has no free address, so the cluster must go to the second |
| `names-vpcs` | Two candidates in different VPCs, with no `vpc_name` |
| `ha-nlb` | As `ha`, behind an internal load balancer. Not in the default set: the provider waits about 65 seconds for the load balancer |

The `*-names` cases pass on this branch: the security groups stay when the subnet comes from `subnet_names` (bbaliyan/cloud-hub#244). A branch that takes the VPC from the lookup that waits for the subnet choice replaces them, and these cases then fail.

All inputs are synthetic.

## Run it

`EMULATOR` picks the AWS emulator: `moto` (default) or `fakecloud`.
`tests/state-migration/emulator.sh <emulator> start|stop|endpoint` holds the binary, the port and the environment of each emulator, one file per emulator in `emulators/`.
The cases and the seed are the same for both.

1. Start an empty emulator where it is installed. Set `SM_MOTO_BIN` or `SM_FAKECLOUD_BIN` if the binary is not on the `PATH`:

   ```sh
   tests/state-migration/emulator.sh moto start
   ```

2. Run the check in the kube-devenv image, on the host network:

   ```sh
   make -j9 -k state-migration EMULATOR=moto
   ```

   `-j9` runs the cases at the same time. They share the seed and the emulator, and each has its own state file.
   To run one case, set `SM_CASES`, for example `SM_CASES=ha-nlb`.

CI runs this on pull requests that touch the AWS modules, `node-bootstrap`, this directory or the Makefile, and on pushes to main. The job runs `make state-migration-ci`, which installs moto 5.2.5 in a venv, starts it and runs all cases. A failed job uploads each `changes.txt`.

3. Read the result in `/tmp/state-migration/<case>/changes.txt`.

The emulator must be empty: the seed creates resources by name.
Restart the emulator before each run. `emulator.sh start` does this. The check stops if the emulator is not empty.
If another program holds the port, `emulator.sh` stops with an error after 30 seconds. Set `SM_EMULATOR_PORT` (also a make variable) to use another port.
The check sets its own AWS environment for every `tofu` call: dummy credentials and an endpoint on 127.0.0.1. It drops `AWS_PROFILE`, `AWS_SESSION_TOKEN` and every other `AWS_*` variable of the caller.

## Emulators

| Emulator | Status |
|---|---|
| moto 5.2.5 | Runs every case. |
| fakecloud 0.51.0 (`FAKECLOUD_EC2_BACKEND=none`, EC2 is metadata only) | Fails in every case at `data.aws_ec2_instance_type` (verified directly with `describe-instance-types` and with the provider). Its `DescribeInstanceTypes` returns a fixed list of 9 x86_64 types, ignores the `instance-type` filter, and lists no arm64 type. Later steps are not yet reached. |

## Limits

- Architecture. The node architecture comes from `data.aws_ec2_instance_type`, so the `arm` case exercises that on moto. The AMI lookup by name, with its `architecture` filter, is NOT exercised on moto, because moto does not store the AMI architecture. The cases give each group the seed AMI of its own architecture instead. On fakecloud nothing about architecture is exercised, because the instance-type lookup fails first.
- The cases pass `os_image_ami_id` and `hosted_zone_id`. Emulators do not store the AMI architecture or the private flag of a zone, so the lookups by name find nothing.
- No node boots. The emulator stores the instances only.
- The emulator does not enforce AWS limits such as the user data size.
- Most of the run is the provider waiting for resources to become ready, not work. The log shows the time of each step.

## Self-test

`make state-migration-selftest` renames the control-plane module without a `moved` block.
It passes only if the check fails and lists the deleted nodes.
Restart the emulator before you run it.
It uses `single-ids`.
