# SPDX-License-Identifier: Apache-2.0
# Guards the Cluster API path: that it is genuinely absent when off, that each
# group renders its own machine template and MachineDeployment, that a tainted
# group carries what cluster-autoscaler needs to scale it off zero, and that the
# preconditions fire rather than baking a broken join address into every worker.

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
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "off_by_default_creates_nothing" {
  command = plan

  assert {
    condition     = length(module.cluster_autoscaler_worker_bootstrap) == 0
    error_message = "no autoscaler worker cloud-init should be rendered when the feature is off"
  }
  assert {
    condition     = length(aws_iam_role.autoscaler_worker) == 0
    error_message = "no CAPI worker IAM role should exist when the feature is off"
  }
  assert {
    condition     = local.cluster_autoscaler_bundle_yaml == ""
    error_message = "the CAPI bundle must be empty when the feature is off, so nothing is written to the genesis node"
  }
  assert {
    condition     = !can(local.autoscaler_platform_helm_parameters.clusterApiEnabled)
    error_message = "the platform Applications must stay at their own off-by-default when this feature is off"
  }
  assert {
    condition     = output.cluster_autoscaler_worst_case_node_count == 0
    error_message = "worst-case node count must be zero when the feature is off"
  }
}

run "every_group_renders_its_own_deployment" {
  command = apply

  variables {
    cluster_domain             = "eu-west-1.example.net"
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_groups = {
      platform = {
        instance_type     = "t4g.large"
        min_size          = 1
        max_size          = 3
        attach_ingress_sg = true
      }
      reserved = {
        instance_type       = "r5a.large"
        max_size            = 1
        root_volume_size_gb = 40
        node_labels         = { workload = "reserved" }
        node_taints         = ["workload=reserved:NoSchedule"]
      }
    }
  }

  assert {
    condition     = length(local.cluster_autoscaler_genesis_manifests) == 1
    error_message = "the bundle must reach the genesis node as exactly one manifest"
  }
  assert {
    condition = alltrue([
      strcontains(local.cluster_autoscaler_bundle_yaml, "name: bharat-platform"),
      strcontains(local.cluster_autoscaler_bundle_yaml, "name: bharat-reserved"),
    ])
    error_message = "each group must render its own objects, named for the group"
  }
  assert {
    condition     = length(module.cluster_autoscaler_worker_bootstrap) == 2
    error_message = "each group needs its own cloud-init render, since labels and taints are baked into it"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "cluster.x-k8s.io/managed-by: \"\"")
    error_message = "the AWSCluster must be marked externally managed, or CAPA tries to own network fabric Terraform already created"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "host: api.bharat.eu-west-1.example.net")
    error_message = "the endpoint host must be derived from cluster_domain, not from the control plane's own IP -- that would be a dependency cycle, since this bundle is written into that instance's cloud-init"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "httpPutResponseHopLimit: 3")
    error_message = "autoscaled workers run the same Cilium pod-netns path, so they need the same hop limit as every other node here"
  }
  assert {
    condition     = output.cluster_autoscaler_worst_case_node_count == 4
    error_message = "worst-case node count must be every group's maximum added together -- it is the number the spend ceiling is derived from"
  }
}

run "a_tainted_group_can_be_scaled_off_zero" {
  command = apply

  variables {
    cluster_domain             = "eu-west-1.example.net"
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_groups = {
      reserved = {
        instance_type = "r5a.large"
        max_size      = 1
        node_labels   = { workload = "reserved" }
        node_taints   = ["workload=reserved:NoSchedule"]
      }
    }
  }

  assert {
    condition = alltrue([
      strcontains(local.cluster_autoscaler_bundle_yaml, "capacity.cluster-autoscaler.kubernetes.io/cpu: \"2\""),
      strcontains(local.cluster_autoscaler_bundle_yaml, "capacity.cluster-autoscaler.kubernetes.io/memory: \"8192Mi\""),
    ])
    error_message = "without the capacity annotations cluster-autoscaler cannot tell whether a Pending pod would fit a group that has no nodes yet"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "capacity.cluster-autoscaler.kubernetes.io/taints: \"workload=reserved:NoSchedule\"")
    error_message = "a group whose nodes carry a taint must advertise it, or the autoscaler assumes the pod cannot land there and never scales up"
  }
  assert {
    condition     = output.cluster_autoscaler_worker_groups["reserved"].node_labels["kube-compute.io/node-group"] == "reserved"
    error_message = "every group must label its nodes with its own name, which is what the MachineDeployment selector matches"
  }
}

run "an_ingress_group_takes_the_ingress_security_group_and_label" {
  command = apply

  variables {
    cluster_domain             = "eu-west-1.example.net"
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_groups = {
      platform = {
        instance_type     = "t4g.large"
        max_size          = 2
        attach_ingress_sg = true
      }
    }
  }

  assert {
    condition     = length(local.autoscaler_group_render["platform"].security_group_ids) == 2
    error_message = "an ingress group needs the external-ports security group as well as the east-west one, or Traefik answers on a node nothing can reach"
  }
  assert {
    condition     = output.cluster_autoscaler_worker_groups["platform"].node_labels["kube-compute.io/ingress"] == "true"
    error_message = "the ingress label travels with the security group -- it is how external-dns picks the nodes to publish"
  }
}

run "enabled_without_a_domain_fails" {
  command         = plan
  expect_failures = [terraform_data.autoscaler_registration_address_configured]

  variables {
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_groups = {
      platform = { instance_type = "t4g.large", max_size = 2 }
    }
  }
}

run "enabled_without_platform_gitops_fails" {
  command         = plan
  expect_failures = [terraform_data.autoscaler_requires_platform_gitops]

  variables {
    cluster_domain             = "eu-west-1.example.net"
    gitops_platform_enabled    = false
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_groups = {
      platform = { instance_type = "t4g.large", max_size = 2 }
    }
  }
}

run "enabled_with_no_groups_is_rejected" {
  command         = plan
  expect_failures = [var.cluster_autoscaler_worker_groups]

  variables {
    cluster_domain             = "eu-west-1.example.net"
    cluster_autoscaler_enabled = true
  }
}

run "a_long_cluster_name_still_fits_the_iam_name_prefix_cap" {
  command = plan

  variables {
    cluster_name               = "cluster-sql-multinode-abcdefghi"
    cluster_domain             = "eu-west-1.example.net"
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_groups = {
      platform = { instance_type = "t4g.large", max_size = 2 }
    }
  }

  assert {
    condition     = length(local.autoscaler_role_name_prefix) <= 38
    error_message = "an IAM name_prefix over 38 characters is rejected by AWS at apply time, after the rest of the plan has already been created"
  }
  assert {
    condition     = endswith(local.autoscaler_role_name_prefix, "-capi-")
    error_message = "truncation must take the cluster name, not the suffix that distinguishes these roles from the control-plane one"
  }
}
