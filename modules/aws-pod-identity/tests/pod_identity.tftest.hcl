# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      domain_name = "d111111abcdef8.cloudfront.net"
      arn         = "arn:aws:cloudfront::mock-account:distribution/EDFDVBD6EXAMPLE"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = {
      id  = "kube-compute-oidc-example"
      arn = "arn:aws:s3:::kube-compute-oidc-example"
    }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::mock-account:oidc-provider/d111111abcdef8.cloudfront.net" }
  }
}

override_data {
  target = data.aws_caller_identity.pod_identity
  values = { account_id = "mock-account" }
}

variables {
  cluster_name = "example"
  aws_region   = "eu-west-1"
}

run "the_bucket_is_private_and_encrypted_and_versioned" {
  command = plan

  assert {
    condition = (
      aws_s3_bucket_public_access_block.issuer.block_public_acls &&
      aws_s3_bucket_public_access_block.issuer.block_public_policy &&
      aws_s3_bucket_public_access_block.issuer.ignore_public_acls &&
      aws_s3_bucket_public_access_block.issuer.restrict_public_buckets
    )
    error_message = "Block Public Access must be fully on"
  }
  assert {
    condition     = aws_s3_bucket_versioning.issuer.versioning_configuration[0].status == "Enabled"
    error_message = "versioning must be on"
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.issuer.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "the bucket must encrypt at rest"
  }
}

run "the_bucket_policy_is_tls_only_distribution_only_and_write_once" {
  command = plan

  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.issuer.policy).Statement :
      s.Effect == "Deny" && s.Action == "s3:*" && s.Condition.Bool["aws:SecureTransport"] == "false"
    ])
    error_message = "the bucket policy must deny every request that is not TLS"
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.issuer.policy).Statement :
      s.Effect == "Allow" && s.Principal.Service == "cloudfront.amazonaws.com" && s.Action == "s3:GetObject" &&
      s.Condition.StringEquals["AWS:SourceArn"] == "arn:aws:cloudfront::mock-account:distribution/EDFDVBD6EXAMPLE"
    ])
    error_message = "only the issuer distribution may read the bucket"
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_s3_bucket_policy.issuer.policy).Statement :
      s.Effect == "Deny" && s.Action == "s3:PutObject" && endswith(s.Resource, "/keys.json") &&
      s.Condition.StringNotEquals["s3:if-none-match"] == "*"
    ])
    error_message = "keys.json must be write-once: a put without if-none-match = * must be denied"
  }
}

run "the_discovery_document_matches_the_issuer" {
  command = plan

  assert {
    condition     = output.issuer_url == "https://d111111abcdef8.cloudfront.net"
    error_message = "the issuer is the CloudFront domain with no trailing slash"
  }
  assert {
    condition     = aws_s3_object.discovery.key == ".well-known/openid-configuration"
    error_message = "the discovery document must sit at the well-known path"
  }
  assert {
    condition = (
      jsondecode(aws_s3_object.discovery.content).issuer == output.issuer_url &&
      jsondecode(aws_s3_object.discovery.content).jwks_uri == "https://d111111abcdef8.cloudfront.net/keys.json" &&
      jsondecode(aws_s3_object.discovery.content).response_types_supported == ["id_token"] &&
      jsondecode(aws_s3_object.discovery.content).subject_types_supported == ["public"] &&
      jsondecode(aws_s3_object.discovery.content).id_token_signing_alg_values_supported == ["RS256"]
    )
    error_message = "the discovery document must carry the issuer, the jwks_uri and the supported types"
  }
  assert {
    condition     = aws_iam_openid_connect_provider.issuer.url == output.issuer_url && aws_iam_openid_connect_provider.issuer.client_id_list == toset(["sts.amazonaws.com"])
    error_message = "the OIDC provider must use the same issuer and the sts.amazonaws.com client"
  }
}

run "only_the_ebs_csi_role_exists_by_default" {
  command = plan

  assert {
    condition     = keys(aws_iam_role.workload) == ["ebs_csi"]
    error_message = "without options only the EBS CSI role may exist"
  }
  assert {
    condition = (
      output.role_arns.cluster_autoscaler == null &&
      output.role_arns.external_dns == null &&
      output.role_arns.external_secrets == null
    )
    error_message = "the optional role ARNs must be null when the roles are not created"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.ebs_csi.policy_arn == "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    error_message = "the EBS CSI role must carry the AWS managed driver policy"
  }
}

run "roles_trust_one_service_account_and_the_sts_audience" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.workload["ebs_csi"].assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" &&
      jsondecode(aws_iam_role.workload["ebs_csi"].assume_role_policy).Statement[0].Condition.StringEquals == {
        "d111111abcdef8.cloudfront.net:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        "d111111abcdef8.cloudfront.net:aud" = "sts.amazonaws.com"
      }
    )
    error_message = "the role must pin the sub and the aud of the issuer"
  }
}

run "service_account_names_can_be_overridden" {
  command = plan

  variables {
    service_accounts = {
      ebs_csi = { name = "custom-sa" }
    }
  }

  assert {
    condition     = jsondecode(aws_iam_role.workload["ebs_csi"].assume_role_policy).Statement[0].Condition.StringEquals["d111111abcdef8.cloudfront.net:sub"] == "system:serviceaccount:kube-system:custom-sa"
    error_message = "an overridden name must reach the trust policy and the namespace must keep its default"
  }
}

run "autoscaler_role_exists_only_with_autoscaling" {
  command = plan

  variables {
    autoscaling_enabled    = true
    autoscaling_group_arns = ["arn:aws:autoscaling:eu-west-1:mock-account:autoScalingGroup:x:autoScalingGroupName/asg-a"]
  }

  assert {
    condition     = contains(keys(aws_iam_role.workload), "cluster_autoscaler") && !contains(keys(aws_iam_role.workload), "external_dns")
    error_message = "autoscaling_enabled must add the cluster-autoscaler role and nothing else"
  }
  assert {
    condition     = jsondecode(aws_iam_role.workload["cluster_autoscaler"].assume_role_policy).Statement[0].Condition.StringEquals["d111111abcdef8.cloudfront.net:sub"] == "system:serviceaccount:cluster-autoscaler:cluster-autoscaler-aws-cluster-autoscaler"
    error_message = "the autoscaler role must trust the autoscaler service account"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.workload["cluster_autoscaler"].policy).Statement[1].Resource ==
      ["arn:aws:autoscaling:eu-west-1:mock-account:autoScalingGroup:x:autoScalingGroupName/asg-a"]
    )
    error_message = "scaling must be limited to the given autoscaling groups"
  }
}

run "external_dns_and_external_secrets_roles_appear_when_given_inputs" {
  command = plan

  variables {
    external_dns_hosted_zone_ids       = ["Z0123456789ABC"]
    external_secrets_ssm_path_prefixes = ["/platform/"]
  }

  assert {
    condition     = contains(keys(aws_iam_role.workload), "external_dns") && contains(keys(aws_iam_role.workload), "external_secrets") && !contains(keys(aws_iam_role.workload), "cluster_autoscaler")
    error_message = "the two optional roles must exist when their inputs are given"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.workload["external_dns"].policy).Statement[0].Resource == ["arn:aws:route53:::hostedzone/Z0123456789ABC"]
    error_message = "external-dns may change only the given zones"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.workload["external_secrets"].policy).Statement[0].Resource == ["arn:aws:ssm:eu-west-1:mock-account:parameter/platform/*"]
    error_message = "External Secrets may read only the given path prefixes"
  }
}

run "an_ssm_prefix_without_a_leading_slash_is_rejected" {
  command = plan

  variables {
    external_secrets_ssm_path_prefixes = ["platform/"]
  }

  expect_failures = [var.external_secrets_ssm_path_prefixes]
}

run "the_keys_policy_allows_one_object_and_is_not_attached" {
  command = plan

  assert {
    condition = (
      jsondecode(output.keys_put_policy_json).Statement[0].Action == "s3:PutObject" &&
      jsondecode(output.keys_put_policy_json).Statement[0].Resource == "arn:aws:s3:::kube-compute-oidc-example/keys.json"
    )
    error_message = "the policy must allow s3:PutObject on keys.json only"
  }
}

run "the_ssm_region_defaults_to_the_cluster_region" {
  command = plan

  variables {
    external_secrets_ssm_path_prefixes = ["/platform/"]
  }

  assert {
    condition = (
      aws_iam_role_policy.workload["external_secrets"].policy == jsonencode(local.role_policies["external_secrets"]) &&
      alltrue([for arn in local.ssm_parameter_arns : startswith(arn, "arn:aws:ssm:eu-west-1:")]) &&
      local.role_policies["external_secrets"].Statement[1].Condition.StringEquals["kms:ViaService"] == "ssm.eu-west-1.amazonaws.com"
    )
    error_message = "the SSM region must default to aws_region"
  }
}

run "the_ssm_region_can_differ_from_the_cluster_region" {
  command = plan

  variables {
    external_secrets_ssm_path_prefixes = ["/platform/"]
    external_secrets_ssm_region        = "eu-central-1"
  }

  assert {
    condition = (
      alltrue([for arn in local.ssm_parameter_arns : startswith(arn, "arn:aws:ssm:eu-central-1:")]) &&
      local.role_policies["external_secrets"].Statement[1].Condition.StringEquals["kms:ViaService"] == "ssm.eu-central-1.amazonaws.com"
    )
    error_message = "the SSM region input must reach the policy"
  }
}
