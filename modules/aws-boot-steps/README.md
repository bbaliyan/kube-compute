# aws-boot-steps

Renders the boot steps that only an AWS node needs. It produces text and creates no resource.

Pass the `steps` output to the `provider_steps` input of `node-bootstrap`.

## Steps

- `ssm-agent` always runs. It starts SSM Agent, which is the operator's access path to the node.
- `aws-provider-id` runs when `aws_provider_id` is true. It reads the zone, the instance ID and the instance type from EC2 metadata. It then writes an RKE2 `config.yaml.d` drop-in. The drop-in sets the node providerID and the `node.kubernetes.io/instance-type` label.

cluster-autoscaler and the AWS cloud controller manager find the instance of a node by its providerID. Every role takes the label, control plane included.

## Inputs and outputs

| Name | Purpose |
|------|---------|
| `aws_provider_id` | Turns on the `aws-provider-id` step. Default `false`. |
| `steps` | A list of `{ name, commands }` for `provider_steps`. |
