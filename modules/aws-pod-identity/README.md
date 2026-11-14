# aws-pod-identity

This module lets pods get AWS credentials from a signed token of their own service account. They do not need the node role.

It creates a token issuer and one IAM role for each platform workload. `aws-cluster` calls it. Nothing uses the issuer or the roles yet, and the node role keeps all its permissions.

AWS only. Proxmox has no instance metadata service, so it has nothing to replace.

## What it creates

- A private S3 bucket with Block Public Access, a TLS-only policy, encryption and versioning.
- A CloudFront distribution with origin access control. Only this distribution can read the bucket.
- A discovery document at `/.well-known/openid-configuration`. It points `jwks_uri` at `/keys.json`.
- An IAM OIDC provider for the issuer URL, with the client `sts.amazonaws.com`.
- IAM roles. Each role trusts one service account (`sub`) and the audience `sts.amazonaws.com` (`aud`).
  - `ebs_csi`: always.
  - `cluster_autoscaler`: only when `autoscaling_enabled` is true.
  - `external_dns`: only when `external_dns_hosted_zone_ids` is not empty.
  - `external_secrets`: only when `external_secrets_ssm_path_prefixes` is not empty.

## Cost

Anyone can request the public files. A long cache (1 hour to 24 hours) caps the requests that reach the bucket. You should set an AWS Budget alert on the account. That is the job of the consumer.

## The signing keys

The module does not create `keys.json`. A later step must publish the public signing keys of the cluster to that one object.

The bucket policy makes the object write-once. A put request must send `If-None-Match: *`. A second write fails for every principal.

The `keys_put_policy_json` output allows `s3:PutObject` on that one object. The module does not attach it. Attach it to the control-plane role.

## The issuer URL

The issuer URL is the CloudFront domain with no trailing slash. Use the `issuer_url` output everywhere: the API server flag, the discovery document and the trust policies. The token `iss` claim must equal it exactly.

## Service accounts

The defaults match the names that the kube-platform charts create. If your chart values rename a service account, set `service_accounts`.

## Inputs and outputs

<!-- BEGIN_TF_DOCS -->
### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_autoscaling_enabled"></a> [autoscaling\_enabled](#input\_autoscaling\_enabled) | Create the cluster-autoscaler role. Set it to true when the cluster has autoscaled nodes. It is a flag, not a list check, because the group ARNs are not known at plan time. | `bool` | `false` | no |
| <a name="input_autoscaling_group_arns"></a> [autoscaling\_group\_arns](#input\_autoscaling\_group\_arns) | ARNs of the autoscaling groups that the cluster-autoscaler role may scale. Used only when autoscaling\_enabled is true. | `list(string)` | `[]` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | Region of the SSM parameters that the External Secrets role reads. | `string` | n/a | yes |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Cluster identity. Used in the names of the IAM roles and in tags. Lowercase, starts with a letter or digit. | `string` | n/a | yes |
| <a name="input_external_dns_hosted_zone_ids"></a> [external\_dns\_hosted\_zone\_ids](#input\_external\_dns\_hosted\_zone\_ids) | Route53 hosted zone IDs that external-dns may change. An empty list creates no external-dns role: the consumer keeps its own policy. | `list(string)` | `[]` | no |
| <a name="input_external_secrets_ssm_path_prefixes"></a> [external\_secrets\_ssm\_path\_prefixes](#input\_external\_secrets\_ssm\_path\_prefixes) | SSM parameter path prefixes that External Secrets may read, such as /platform/. Each must start with a slash. An empty list creates no External Secrets role. | `list(string)` | `[]` | no |
| <a name="input_service_accounts"></a> [service\_accounts](#input\_service\_accounts) | Namespace and name of the service account each role trusts. The defaults are the names the kube-platform charts create. Override a workload only if your chart values rename its service account. | <pre>object({<br/>    ebs_csi = optional(object({<br/>      namespace = optional(string, "kube-system")<br/>      name      = optional(string, "ebs-csi-controller-sa")<br/>    }), {})<br/>    cluster_autoscaler = optional(object({<br/>      namespace = optional(string, "cluster-autoscaler")<br/>      name      = optional(string, "cluster-autoscaler-aws-cluster-autoscaler")<br/>    }), {})<br/>    external_dns = optional(object({<br/>      namespace = optional(string, "external-dns")<br/>      name      = optional(string, "external-dns")<br/>    }), {})<br/>    external_secrets = optional(object({<br/>      namespace = optional(string, "external-secrets")<br/>      name      = optional(string, "external-secrets")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags for every resource this module creates. | `map(string)` | `{}` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_bucket_name"></a> [bucket\_name](#output\_bucket\_name) | Name of the private bucket that holds the discovery document and keys.json. |
| <a name="output_issuer_url"></a> [issuer\_url](#output\_issuer\_url) | The token issuer URL: the CloudFront domain with no trailing slash. Use this one value for the API server flag, the discovery document and every trust policy. |
| <a name="output_keys_put_policy_json"></a> [keys\_put\_policy\_json](#output\_keys\_put\_policy\_json) | IAM policy that allows s3:PutObject on the one keys.json object. Attach it to the control-plane role. The bucket policy makes the object write-once. |
| <a name="output_role_arns"></a> [role\_arns](#output\_role\_arns) | Map of workload to IAM role ARN, with the keys ebs\_csi, cluster\_autoscaler, external\_dns and external\_secrets. A role that was not created is null. |
<!-- END_TF_DOCS -->
