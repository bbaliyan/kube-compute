# Consumer region-hierarchy example (AWS)

Demonstrates the layout a consumer repo uses to organize multiple clusters across
regions, per ADR 0001 (region-scoping is structural, not a variable):

```
live/aws/
  root.hcl                          # anchor; find_in_parent_folders() target
  common.hcl                        # shared backend + module source pin
  <region>/
    region.hcl                      # sets the provider region for this subtree
    clusters/
      <cluster>/
        spine/terragrunt.hcl        # every cluster has exactly one spine unit
        pools/
          <az>/terragrunt.hcl       # one pool unit per AZ, `dependency` on ../../spine
```

This tree contains three example clusters:

- `eu-west-1/clusters/demo/spine` — single-node (spine only, no pools).
- `us-east-1/clusters/demo/spine` — same cluster name as above, different region — proves
  the S3 state key doesn't collide (the key is derived from each unit's own path, which
  already includes the region and cluster name).
- `eu-west-1/clusters/demo-ha/{spine,pools/eu-west-1a,pools/eu-west-1b}` — HA (3
  control-plane nodes, one per AZ) with two AZ-pinned worker pools, each pool declaring a
  Terragrunt `dependency` on the spine for `registration_address`,
  `agent_token_ssm_parameter`, and `cluster_security_group_id`.

Every value here is a placeholder — swap the subnet IDs, `allowed_ingress_cidrs`, and
`state_bucket` for your own before applying anything for real.

For a real, deployed instance of this shape (single-node, brownfield VPC, real values),
see the private consumer repo `kube-devclusters` at
`live/aws/clusters/cluster-1/terragrunt.hcl` — that repo predates this layout (it has no
per-region subtree yet, since it only has one region/cluster so far) but uses the same
`common.hcl`/`cluster-defaults.hcl` include pattern this example is built on.

Validate offline (no AWS credentials/backend needed). Every unit supports the pure
HCL/schema check:

```bash
cd <any clusters/<cluster>/spine or pools/<az> dir>
terragrunt hcl validate
```

`spine` units (no `dependency` block) also support a full OpenTofu-level validate,
skipping the S3 backend entirely:

```bash
cd <any clusters/<cluster>/spine dir>
TF_CLI_ARGS_init="-backend=false" terragrunt run validate --non-interactive
```

`pools/<az>` units declare a `dependency "spine"` block. Terragrunt's real
dependency-output fetch needs the spine's actual (applied) remote state, so a
never-applied pool unit's full `run validate` fails offline even though
`mock_outputs` are configured. Use `terragrunt hcl validate --inputs` instead — it
resolves the dependency from `mock_outputs` and cross-checks every input against the
module's `variable` blocks without touching any backend:

```bash
cd <any pools/<az> dir>
terragrunt hcl validate --inputs
```
