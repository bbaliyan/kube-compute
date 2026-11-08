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
7. The check fails on a create, delete or replace that `allowed/<case>.txt` does not list.

## Cases

| Case | Shape |
|---|---|
| `single` | One `all_in_one` node |
| `multi` | A dedicated control plane, a static node group and an autoscaled node group |

All inputs are synthetic.

## Run it

1. Start an empty AWS emulator on port 4566, for example `moto_server -p 4566` with `MOTO_IAM_LOAD_MANAGED_POLICIES=true`.
2. Run the check in the kube-devenv image, on the host network:

   ```sh
   AWS_ENDPOINT_URL=http://127.0.0.1:4566 make state-migration
   ```

3. Read the result in `/tmp/state-migration/<case>/changes.txt`.

The emulator must be empty: the seed creates resources by name.
Restart the emulator before each run.

## Limits

- The cases pass `os_image_ami_id` and `hosted_zone_id`. Emulators do not store the AMI architecture or the private flag of a zone, so the lookups by name find nothing.
- No node boots. The emulator stores the instances only.
- The emulator does not enforce AWS limits such as the user data size.
