# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
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

run "the_guard_is_on_by_default" {
  command = plan

  assert {
    condition = (
      local.platform_helm_values_object.imdsGuard.enabled == true &&
      tolist(local.platform_helm_values_object.imdsGuard.allowedNamespaces) == tolist(["kube-system", "external-secrets", "cluster-autoscaler", "external-dns"])
    )
    error_message = "a new cluster must block the metadata service for every pod outside the platform's own namespaces"
  }
  assert {
    condition     = local.platform_extra_helm_parameters.awsRegion == "eu-west-1"
    error_message = "the guard refuses to render without awsRegion, so the region must be set even without autoscaling"
  }
}

run "extra_namespaces_join_the_allow_list" {
  command = plan

  variables {
    imds_allowed_extra_namespaces = ["metrics", "external-dns"]
    platform_node_group           = "platform"
    static_nodes = {
      platform = { instance_type = "t3a.xlarge" }
    }
  }

  assert {
    condition     = tolist(local.platform_helm_values_object.imdsGuard.allowedNamespaces) == tolist(["kube-system", "external-secrets", "cluster-autoscaler", "external-dns", "metrics"])
    error_message = "extra namespaces must extend the platform's list, once each"
  }
  assert {
    condition     = local.platform_helm_values_object.platformNodeSelector["kube-compute.io/node-group"] == "platform"
    error_message = "the guard must not displace the other platform values"
  }
}

run "platform_values_can_replace_the_guard" {
  command = plan

  variables {
    platform_helm_values_object = { imdsGuard = { enabled = false } }
  }

  assert {
    condition     = length(local.platform_helm_values_object.imdsGuard) == 1 && local.platform_helm_values_object.imdsGuard.enabled == false
    error_message = "platform_helm_values_object must win over the module's guard values"
  }
}
