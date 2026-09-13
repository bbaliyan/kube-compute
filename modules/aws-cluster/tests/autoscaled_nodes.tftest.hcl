# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "no_groups_means_no_autoscaling" {
  command = plan

  assert {
    condition     = length(module.autoscaled_nodes) == 0 && length(aws_iam_role_policy.autoscaling) == 0
    error_message = "without autoscaled_nodes nothing may be created for autoscaling"
  }
  assert {
    condition     = length(local.platform_extra_helm_parameters) == 0
    error_message = "without autoscaled_nodes the platform Application must be unchanged, or every existing control plane is replaced"
  }
}

run "groups_join_the_control_planes_zone_and_the_platform_can_scale_them" {
  command = apply

  variables {
    cluster_type        = "dedicated_control_plane"
    platform_node_group = "platform"
    static_nodes = {
      platform = { instance_type = "t3a.xlarge" }
    }
    autoscaled_nodes = {
      reserved      = { instance_type = "r5a.large", max_size = 1, node_taints = ["workload=reserved:NoSchedule"] }
      workers-large = { instance_type = "t3a.large", max_size = 2 }
    }
  }

  assert {
    condition     = alltrue([for g in module.autoscaled_nodes : g.subnet_id == module.control_plane.subnet_id])
    error_message = "every group must launch into the control plane's subnet -- an EBS volume cannot cross availability zones"
  }
  assert {
    condition = (
      local.platform_extra_helm_parameters.clusterAutoscalerEnabled == "true" &&
      local.platform_extra_helm_parameters.clusterAutoscalerCloudProvider == "aws" &&
      local.platform_extra_helm_parameters.awsRegion == "eu-west-1"
    )
    error_message = "the platform Application must run cluster-autoscaler against this region's Auto Scaling groups"
  }
  assert {
    condition     = aws_iam_role_policy.autoscaling[0].role == module.static_nodes["platform"].node_iam_role_name
    error_message = "the autoscaler and cloud controller manager run on the platform node, so its role must carry their permissions"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.autoscaling[0].policy).Statement[1].Resource == [for g in module.autoscaled_nodes : g.autoscaling_group_arn]
    error_message = "scaling and terminating must be limited to this cluster's own groups"
  }
  assert {
    condition     = alltrue([for g in module.autoscaled_nodes : contains(output.workload_node_iam_role_names, g.node_iam_role_name)])
    error_message = "workloads run on autoscaled nodes, so their roles must be among the workload roles"
  }
  assert {
    condition     = output.autoscaled_nodes["reserved"].node_taints == tolist(["workload=reserved:NoSchedule"])
    error_message = "the output must surface each group's taints"
  }
}

run "a_group_that_can_never_have_a_node_is_rejected" {
  command = plan

  variables {
    autoscaled_nodes = {
      workers = { instance_type = "t3a.large", max_size = 0 }
    }
  }

  expect_failures = [var.autoscaled_nodes]
}

run "autoscaling_without_the_platform_is_rejected" {
  command = plan

  variables {
    gitops_platform_enabled = false
    autoscaled_nodes = {
      workers = { instance_type = "t3a.large", max_size = 2 }
    }
  }

  expect_failures = [var.autoscaled_nodes]
}
