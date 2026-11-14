# SPDX-License-Identifier: Apache-2.0

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
}

run "pod_identity_is_off_by_default" {
  command = plan

  assert {
    condition     = length(module.pod_identity) == 0
    error_message = "pod identity must create nothing unless pod_identity_enabled is true"
  }
  assert {
    condition     = output.pod_identity_issuer_url == null && output.pod_identity_role_arns == null && output.pod_identity_keys_put_policy_json == null
    error_message = "the pod identity outputs must be null when it is off"
  }
}

run "pod_identity_can_be_turned_on" {
  command = plan

  variables {
    pod_identity_enabled = true
  }

  assert {
    condition     = length(module.pod_identity) == 1
    error_message = "pod_identity_enabled must create the module"
  }
  assert {
    condition     = output.pod_identity_issuer_url == "https://d111111abcdef8.cloudfront.net"
    error_message = "the issuer URL must reach the output"
  }
  assert {
    condition     = length(aws_iam_role_policy.pod_identity_keys) == 1 && aws_iam_role_policy.pod_identity_keys[0].policy == output.pod_identity_keys_put_policy_json
    error_message = "the control-plane role must carry the keys put policy"
  }
  assert {
    condition = (
      local.platform_extra_helm_parameters["awsPodIdentity.enabled"] == "true" &&
      contains(keys(local.platform_extra_helm_parameters), "awsPodIdentity.roles.ebsCsi") &&
      !contains(keys(local.platform_extra_helm_parameters), "awsPodIdentity.roles.clusterAutoscaler") &&
      !contains(keys(local.platform_extra_helm_parameters), "awsPodIdentity.roles.externalDns") &&
      !contains(keys(local.platform_extra_helm_parameters), "awsPodIdentity.roles.externalSecrets")
    )
    error_message = "the platform gets the switch and only the roles that exist"
  }
}

run "the_optional_roles_reach_the_platform" {
  command = plan

  variables {
    pod_identity_enabled               = true
    external_dns_hosted_zone_ids       = ["Z0123456789ABC"]
    external_secrets_ssm_path_prefixes = ["/platform/"]
    autoscaled_nodes = {
      burst = { instance_types = ["m6i.large"], max_cpu_cores = 8, max_memory_gib = 32 }
    }
  }

  assert {
    condition = alltrue([
      for name in ["ebsCsi", "clusterAutoscaler", "externalDns", "externalSecrets"] :
      contains(keys(local.platform_extra_helm_parameters), "awsPodIdentity.roles.${name}")
    ])
    error_message = "every role that exists must be a platform parameter"
  }
}

run "pod_identity_off_adds_no_platform_parameter_and_no_policy" {
  command = plan

  assert {
    condition     = !anytrue([for key in keys(local.platform_extra_helm_parameters) : startswith(key, "awsPodIdentity")]) && length(aws_iam_role_policy.pod_identity_keys) == 0
    error_message = "with pod identity off the platform parameters and the roles are as before"
  }
}

# An ARN is unknown at plan time. The keys must come from the input flags, so the plan can
# count them. This fails with "unknown" if a key depends on an ARN.
run "the_platform_parameter_keys_come_from_inputs" {
  command = plan

  variables {
    pod_identity_enabled         = true
    external_dns_hosted_zone_ids = ["Z0123456789ABC"]
  }

  assert {
    condition = (
      sort(keys(local.pod_identity_helm_parameters)) == sort([
        "awsPodIdentity.enabled",
        "awsPodIdentity.roles.ebsCsi",
        "awsPodIdentity.roles.externalDns",
      ])
    )
    error_message = "the keys must follow the flags: the always-on roles and the external-dns zones"
  }
}

# A root test cannot read the policy inside the module. This run verifies that the input is
# accepted and planned through the module. The policy itself is tested in aws-pod-identity.
run "external_dns_record_name_patterns_reach_the_pod_identity_module" {
  command = plan

  variables {
    pod_identity_enabled              = true
    external_dns_hosted_zone_ids      = ["Z0123456789ABC"]
    external_dns_record_name_patterns = ["sql*.example.com"]
  }

  assert {
    condition     = length(module.pod_identity) == 1
    error_message = "valid patterns must plan with pod identity on"
  }
}
