# SPDX-License-Identifier: Apache-2.0
# Guards the Cluster API path: that it is genuinely absent when off, that the
# bundle it genesis-applies carries the fields CAPA needs, and that the two
# preconditions fire rather than baking a broken join address into every worker.

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

run "enabled_renders_the_capa_bundle" {
  command = apply

  variables {
    cluster_domain                     = "eu-west-1.example.net"
    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 0
    cluster_autoscaler_worker_max_size = 3
    cluster_autoscaler_worker_template = {
      instance_type       = "t4g.large"
      root_volume_size_gb = 40
    }
  }

  assert {
    condition     = length(local.cluster_autoscaler_genesis_manifests) == 1
    error_message = "the bundle must reach the genesis node as exactly one manifest"
  }
  assert {
    condition = alltrue([
      strcontains(local.cluster_autoscaler_bundle_yaml, "kind: AWSCluster"),
      strcontains(local.cluster_autoscaler_bundle_yaml, "kind: AWSMachineTemplate"),
      strcontains(local.cluster_autoscaler_bundle_yaml, "kind: MachineDeployment"),
    ])
    error_message = "the bundle must carry the AWSCluster the machine reconciler does a hard Get on, the machine template, and the MachineDeployment"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "cluster.x-k8s.io/managed-by: \"\"")
    error_message = "the AWSCluster must be marked externally managed, or CAPA tries to own network fabric Terraform already created"
  }
  assert {
    condition = alltrue([
      strcontains(local.cluster_autoscaler_bundle_yaml, "cluster-api-autoscaler-node-group-min-size: \"0\""),
      strcontains(local.cluster_autoscaler_bundle_yaml, "cluster-api-autoscaler-node-group-max-size: \"3\""),
    ])
    error_message = "the min/max annotations are how cluster-autoscaler discovers this group's bounds; without them it will not touch it"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "host: api.bharat.eu-west-1.example.net")
    error_message = "the endpoint host must be derived from cluster_domain, not from the control plane's own IP -- that would be a dependency cycle, since this bundle is written into that instance's cloud-init"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "sshKeyName: \"\"")
    error_message = "an omitted sshKeyName makes CAPA attach the account default; this project has no inbound SSH anywhere"
  }
  assert {
    condition     = strcontains(local.cluster_autoscaler_bundle_yaml, "httpPutResponseHopLimit: 3")
    error_message = "autoscaled workers run the same Cilium pod-netns path, so they need the same hop limit as every other node here"
  }
  assert {
    condition     = local.autoscaler_platform_helm_parameters.clusterApiEnabled == "true" && local.autoscaler_platform_helm_parameters.clusterAutoscalerEnabled == "true"
    error_message = "enabling this must turn on both platform Applications: the autoscaler drives MachineDeployments, which only exist once Cluster API is installed"
  }
  assert {
    condition     = output.cluster_autoscaler_worst_case_node_count == 3
    error_message = "worst-case node count must equal the configured maximum -- it is the number the spend ceiling is derived from"
  }
}

run "enabled_without_a_domain_fails" {
  command         = plan
  expect_failures = [terraform_data.autoscaler_registration_address_configured]

  variables {
    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_max_size = 2
    cluster_autoscaler_worker_template = { instance_type = "t4g.large" }
  }
}

run "enabled_without_platform_gitops_fails" {
  command         = plan
  expect_failures = [terraform_data.autoscaler_requires_platform_gitops]

  variables {
    cluster_domain                     = "eu-west-1.example.net"
    gitops_platform_enabled            = false
    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_max_size = 2
    cluster_autoscaler_worker_template = { instance_type = "t4g.large" }
  }
}

run "max_size_zero_is_rejected" {
  command         = plan
  expect_failures = [var.cluster_autoscaler_worker_max_size]

  variables {
    cluster_domain                     = "eu-west-1.example.net"
    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_template = { instance_type = "t4g.large" }
  }
}
