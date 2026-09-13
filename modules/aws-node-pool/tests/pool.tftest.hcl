# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
  # The Auto Scaling group validates the launch template id's lt- shape.
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

override_data {
  target = data.aws_subnet.selected
  values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
}

variables {
  cluster_name              = "bharat"
  group_name                = "workers"
  aws_region                = "eu-west-1"
  registration_address      = "10.0.1.5"
  agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
  cluster_security_group_id = "sg-cluster123"
  subnet_id                 = "subnet-worker-a"
  instance_type             = "m7g.large"
  max_size                  = 3
}

run "the_group_scales_from_zero_in_its_subnet" {
  command = plan

  assert {
    condition     = aws_autoscaling_group.node.min_size == 0 && aws_autoscaling_group.node.max_size == 3
    error_message = "a group must run between zero and max_size"
  }
  assert {
    condition     = aws_autoscaling_group.node.vpc_zone_identifier == toset(["subnet-worker-a"])
    error_message = "the group must launch only into its own subnet, keeping the cluster in one availability zone"
  }
  assert {
    condition     = aws_launch_template.node.vpc_security_group_ids == toset(["sg-cluster123"])
    error_message = "a node must carry only the cluster's east-west security group"
  }
  assert {
    condition     = aws_launch_template.node.metadata_options[0].http_tokens == "required" && aws_launch_template.node.metadata_options[0].http_put_response_hop_limit == 3
    error_message = "IMDSv2 must be enforced with a hop limit pods can reach it through"
  }
}

run "cluster_autoscaler_can_discover_the_group_and_its_nodes_shape" {
  command = plan

  variables {
    node_labels = { workload = "reserved" }
    node_taints = ["workload=reserved:NoSchedule"]
  }

  assert {
    condition = alltrue([
      for key, value in {
        "k8s.io/cluster-autoscaler/enabled"                                        = "true"
        "k8s.io/cluster-autoscaler/bharat"                                         = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/workload"                   = "reserved"
        "k8s.io/cluster-autoscaler/node-template/label/kube-compute.io/node-group" = "workers"
        "k8s.io/cluster-autoscaler/node-template/taint/workload"                   = "reserved:NoSchedule"
        } : contains([
          for t in aws_autoscaling_group.node.tag : t.value if t.key == key && !t.propagate_at_launch
      ], value)
    ])
    error_message = "the group must carry the discovery tags, and advertise its labels and taints, or cluster-autoscaler cannot scale it from zero"
  }
  assert {
    condition     = output.node_labels["kube-compute.io/node-group"] == "workers" && output.node_labels["topology.kubernetes.io/zone"] == "eu-west-1a"
    error_message = "every node must carry its group and zone labels"
  }
}

run "an_invalid_taint_is_rejected" {
  command = plan

  variables {
    node_taints = ["workload:NoSchedule"]
  }

  expect_failures = [var.node_taints]
}

run "os_image_name_resolves_for_the_instance_types_architecture" {
  command = plan

  override_data {
    target = data.aws_ami.by_name
    values = { id = "ami-byname789" }
  }

  variables {
    os_image_name = "almalinux10-*-kube-image-*"
  }

  assert {
    condition     = aws_launch_template.node.image_id == "ami-byname789"
    error_message = "os_image_name should resolve to the looked-up AMI ID"
  }
}
