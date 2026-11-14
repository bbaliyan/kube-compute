# SPDX-License-Identifier: Apache-2.0

# The token issuer for pod identity. A pod sends a signed service account token to STS.
# STS fetches the discovery document and the signing keys from the issuer URL.
# The bucket stays private: only the CloudFront distribution can read it.

locals {
  keys_object_key      = "keys.json"
  discovery_object_key = ".well-known/openid-configuration"

  # One value for the discovery document, the IAM OIDC provider and every trust policy.
  # The URL has no trailing slash and must equal the "iss" claim of the tokens.
  issuer_host = aws_cloudfront_distribution.issuer.domain_name
  issuer_url  = "https://${local.issuer_host}"

  role_name_prefix = "kube-compute-${var.cluster_name}-"

  account_id = data.aws_caller_identity.pod_identity.account_id

  ssm_region = coalesce(var.external_secrets_ssm_region, var.aws_region)

  ssm_parameter_arns = [for prefix in var.external_secrets_ssm_path_prefixes : "arn:aws:ssm:${local.ssm_region}:${local.account_id}:parameter${prefix}*"]

  # Inline JSON: mock_provider cannot evaluate data.aws_iam_policy_document.
  keys_put_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PublishSigningKeys"
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${aws_s3_bucket.issuer.arn}/${local.keys_object_key}"
    }]
  })

  # Which roles exist, and the service account each one trusts.
  roles = merge(
    { ebs_csi = { name = "ebs-csi", service_account = var.service_accounts.ebs_csi } },
    var.autoscaling_enabled ? {
      cluster_autoscaler = { name = "autoscaler", service_account = var.service_accounts.cluster_autoscaler }
    } : {},
    length(var.external_dns_hosted_zone_ids) > 0 ? {
      external_dns = { name = "external-dns", service_account = var.service_accounts.external_dns }
    } : {},
    length(var.external_secrets_ssm_path_prefixes) > 0 ? {
      external_secrets = { name = "ext-secrets", service_account = var.service_accounts.external_secrets }
    } : {},
  )

  # Inline policies of the roles that have no AWS managed policy.
  role_policies = merge(
    var.autoscaling_enabled ? {
      cluster_autoscaler = {
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "ClusterAutoscalerDiscovery"
            Effect = "Allow"
            Action = [
              "autoscaling:DescribeAutoScalingGroups",
              "autoscaling:DescribeAutoScalingInstances",
              "autoscaling:DescribeLaunchConfigurations",
              "autoscaling:DescribeScalingActivities",
              "autoscaling:DescribeTags",
              "ec2:DescribeImages",
              "ec2:DescribeInstanceTypes",
              "ec2:DescribeLaunchTemplateVersions",
              "ec2:GetInstanceTypesFromInstanceRequirements",
            ]
            Resource = "*"
          },
          {
            Sid      = "ClusterAutoscalerScaling"
            Effect   = "Allow"
            Action   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
            Resource = var.autoscaling_group_arns
          },
        ]
      }
    } : {},
    length(var.external_dns_hosted_zone_ids) > 0 ? {
      external_dns = {
        Version = "2012-10-17"
        Statement = [
          merge(
            {
              Sid      = "ChangeRecords"
              Effect   = "Allow"
              Action   = "route53:ChangeResourceRecordSets"
              Resource = [for id in var.external_dns_hosted_zone_ids : "arn:aws:route53:::hostedzone/${id}"]
            },
            length(var.external_dns_record_name_patterns) > 0 ? {
              Condition = {
                "ForAllValues:StringLike" = { "route53:ChangeResourceRecordSetsNormalizedRecordNames" = var.external_dns_record_name_patterns }
              }
            } : {},
          ),
          {
            Sid      = "ReadZones"
            Effect   = "Allow"
            Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
            Resource = "*"
          },
        ]
      }
    } : {},
    length(var.external_secrets_ssm_path_prefixes) > 0 ? {
      external_secrets = {
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "ReadParameters"
            Effect   = "Allow"
            Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
            Resource = local.ssm_parameter_arns
          },
          {
            Sid    = "DecryptParameters"
            Effect = "Allow"
            Action = "kms:Decrypt"
            # By condition, not resource: alias/aws/ssm has no ARN to name here.
            Resource = "*"
            Condition = {
              StringEquals = {
                "kms:ViaService" = "ssm.${local.ssm_region}.amazonaws.com"
              }
            }
          },
        ]
      }
    } : {},
  )
}

# ---- Bucket ----

resource "aws_s3_bucket" "issuer" {
  bucket_prefix = "kube-compute-oidc-"
  force_destroy = true
  tags          = merge(var.tags, { Name = "kube-compute-${var.cluster_name}-oidc" })
}

resource "aws_s3_bucket_public_access_block" "issuer" {
  bucket                  = aws_s3_bucket.issuer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "issuer" {
  bucket = aws_s3_bucket.issuer.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "issuer" {
  bucket = aws_s3_bucket.issuer.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "issuer" {
  bucket = aws_s3_bucket.issuer.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "issuer" {
  bucket = aws_s3_bucket.issuer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "TlsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.issuer.arn, "${aws_s3_bucket.issuer.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "ReadFromTheDistributionOnly"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.issuer.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.issuer.arn } }
      },
      {
        # The signing keys are published once. A second write to the key is refused for everyone.
        Sid       = "WriteKeysOnce"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.issuer.arn}/${local.keys_object_key}"
        Condition = { StringNotEquals = { "s3:if-none-match" = "*" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.issuer]
}

# ---- CloudFront ----

resource "aws_cloudfront_origin_access_control" "issuer" {
  name                              = "kube-compute-${var.cluster_name}-oidc"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Anyone can request the public files, so a long cache caps the requests that reach the bucket.
resource "aws_cloudfront_cache_policy" "issuer" {
  name        = "kube-compute-${var.cluster_name}-oidc"
  min_ttl     = 3600
  default_ttl = 86400
  max_ttl     = 86400

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

resource "aws_cloudfront_distribution" "issuer" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "kube-compute ${var.cluster_name} service account token issuer"
  price_class     = "PriceClass_100"
  http_version    = "http2and3"
  tags            = var.tags

  origin {
    origin_id                = "issuer-bucket"
    domain_name              = aws_s3_bucket.issuer.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.issuer.id
  }

  default_cache_behavior {
    target_origin_id       = "issuer-bucket"
    viewer_protocol_policy = "https-only"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.issuer.id
    compress               = true
  }

  # Before keys.json is published the bucket answers 403. Cache that for seconds only.
  custom_error_response {
    error_code            = 403
    error_caching_min_ttl = 10
  }

  custom_error_response {
    error_code            = 404
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# ---- Discovery document ----

resource "aws_s3_object" "discovery" {
  bucket       = aws_s3_bucket.issuer.id
  key          = local.discovery_object_key
  content_type = "application/json"

  content = jsonencode({
    issuer                                = local.issuer_url
    jwks_uri                              = "${local.issuer_url}/${local.keys_object_key}"
    response_types_supported              = ["id_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
  })

  depends_on = [aws_s3_bucket_policy.issuer]
}

# ---- IAM ----

# No thumbprint_list: IAM verifies the CloudFront certificate against its trusted roots.
resource "aws_iam_openid_connect_provider" "issuer" {
  url            = local.issuer_url
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

resource "aws_iam_role" "workload" {
  for_each = local.roles

  name = "${local.role_name_prefix}${each.value.name}"
  tags = var.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = aws_iam_openid_connect_provider.issuer.arn }
      Condition = {
        StringEquals = {
          "${local.issuer_host}:sub" = "system:serviceaccount:${each.value.service_account.namespace}:${each.value.service_account.name}"
          "${local.issuer_host}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.workload["ebs_csi"].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "workload" {
  for_each = local.role_policies

  name   = "${local.role_name_prefix}${local.roles[each.key].name}"
  role   = aws_iam_role.workload[each.key].id
  policy = jsonencode(each.value)
}
