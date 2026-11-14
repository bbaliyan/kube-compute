# SPDX-License-Identifier: Apache-2.0
# With pod identity on: hop limit 1, an empty guard allow-list and no autoscaler statements on
# the node role. With it off, none of that changes.

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      domain_name = "d111111abcdef8.cloudfront.net"
      arn         = "arn:aws:cloudfront::mock-account:distribution/EDFDVBD6EXAMPLE"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::kube-compute-oidc-example" }
  }
  mock_data "aws_ec2_instance_type" {
    defaults = {
      supported_architectures = ["x86_64"]
      default_vcpus           = 2
      memory_size             = 8192
    }
  }
}

variables {
  os_image_name         = "kube-image-*"
  cluster_name          = "example"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
  cluster_type          = "dedicated_control_plane"
  platform_node_group   = "platform"
  static_nodes = {
    platform = { instance_type = "t3a.xlarge" }
  }
  autoscaled_nodes = {
    workers = { instance_types = ["t3a.large"], max_cpu_cores = 4, max_memory_gib = 16 }
  }
}

run "off_keeps_hop_limit_three_and_the_node_role_statements" {
  command = plan

  assert {
    condition     = local.imds_hop_limit == 3
    error_message = "without pod identity the hop limit must stay 3"
  }
  assert {
    condition     = length(aws_iam_role_policy.autoscaling) == 1 && length(aws_iam_role_policy.cloud_controller_manager) == 1
    error_message = "without pod identity the node role must keep the autoscaler and cloud controller manager statements"
  }
  assert {
    condition     = tolist(local.platform_helm_values_object.imdsGuard.allowedNamespaces) == tolist(["kube-system", "external-secrets", "cluster-autoscaler", "external-dns"])
    error_message = "without pod identity the guard must keep the platform's own namespaces"
  }
}

run "on_drops_to_hop_limit_one_and_moves_the_statements" {
  command = plan

  variables {
    pod_identity_enabled = true
  }

  assert {
    condition     = local.imds_hop_limit == 1
    error_message = "with pod identity the hop limit must be 1"
  }
  assert {
    condition     = length(aws_iam_role_policy.autoscaling) == 0
    error_message = "with pod identity the autoscaler statements must leave the node role"
  }
  assert {
    condition     = length(aws_iam_role_policy.cloud_controller_manager) == 1 && length(aws_iam_role_policy.pod_identity_keys) == 1
    error_message = "the cloud controller manager and the key publish permission must stay on the control-plane role"
  }
  assert {
    condition     = local.platform_helm_values_object.imdsGuard.enabled == true && length(local.platform_helm_values_object.imdsGuard.allowedNamespaces) == 0
    error_message = "with pod identity the guard must stay on with an empty allow-list"
  }
}

run "on_keeps_the_consumers_extra_namespaces_only" {
  command = plan

  variables {
    pod_identity_enabled          = true
    imds_allowed_extra_namespaces = ["metrics"]
  }

  assert {
    condition     = tolist(local.platform_helm_values_object.imdsGuard.allowedNamespaces) == tolist(["metrics"])
    error_message = "with pod identity only the consumer's own namespaces may stay on the allow-list"
  }
}
