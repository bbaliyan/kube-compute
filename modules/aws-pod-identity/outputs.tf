# SPDX-License-Identifier: Apache-2.0

output "issuer_url" {
  description = "The token issuer URL: the CloudFront domain with no trailing slash. Use this one value for the API server flag, the discovery document and every trust policy."
  value       = local.issuer_url
}

output "role_arns" {
  description = "Map of workload to IAM role ARN, with the keys ebs_csi, cluster_autoscaler, external_dns and external_secrets. A role that was not created is null."
  value = {
    ebs_csi            = try(aws_iam_role.workload["ebs_csi"].arn, null)
    cluster_autoscaler = try(aws_iam_role.workload["cluster_autoscaler"].arn, null)
    external_dns       = try(aws_iam_role.workload["external_dns"].arn, null)
    external_secrets   = try(aws_iam_role.workload["external_secrets"].arn, null)
  }
}

output "keys_put_policy_json" {
  description = "IAM policy that allows s3:PutObject on the one keys.json object. Attach it to the control-plane role. The bucket policy makes the object write-once."
  value       = local.keys_put_policy_json
}

output "bucket_name" {
  description = "Name of the private bucket that holds the discovery document and keys.json."
  value       = aws_s3_bucket.issuer.id
}
