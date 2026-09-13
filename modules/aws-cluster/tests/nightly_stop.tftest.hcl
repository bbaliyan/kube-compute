# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/kube-compute-bharat-stop" }
  }
}

variables {
  cluster_name          = "bharat"
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  subnet_id             = "subnet-abc"
  os_image_ami_id       = "ami-0123456789abcdef0"
}

run "off_by_default_stops_nothing" {
  command = plan

  assert {
    condition     = length(aws_scheduler_schedule.nightly_stop) == 0 && length(aws_scheduler_schedule.nightly_scale_to_zero) == 0
    error_message = "without nightly_stop nothing may stop the nodes or scale the groups"
  }
}

run "a_cluster_without_autoscaling_only_stops_its_nodes" {
  command = apply

  variables {
    nightly_stop = { time = "20:00", timezone = "Australia/Sydney" }
  }

  assert {
    condition     = aws_scheduler_schedule.nightly_stop[0].schedule_expression == "cron(0 20 * * ? *)"
    error_message = "the stop must fire at nightly_stop.time"
  }
  assert {
    condition     = length(aws_scheduler_schedule.nightly_scale_to_zero) == 0 && length(jsondecode(aws_iam_role_policy.nightly_stop[0].policy).Statement) == 1
    error_message = "a cluster without autoscaled groups must only be allowed to stop its instances"
  }
}

run "an_autoscaled_cluster_scales_its_groups_to_zero_as_it_stops" {
  command = apply

  variables {
    nightly_stop = { time = "00:02", timezone = "Europe/London" }
    autoscaled_nodes = {
      workers = { instance_type = "t3a.large", max_size = 2 }
    }
  }

  assert {
    condition = (
      aws_scheduler_schedule.nightly_scale_to_zero["workers"].schedule_expression == aws_scheduler_schedule.nightly_stop[0].schedule_expression &&
      aws_scheduler_schedule.nightly_scale_to_zero["workers"].schedule_expression_timezone == "Europe/London"
    )
    error_message = "a group must go to zero at the moment the nodes stop, when nothing is left to scale it back up"
  }
  assert {
    condition = jsondecode(aws_scheduler_schedule.nightly_scale_to_zero["workers"].target[0].input) == {
      AutoScalingGroupName = module.autoscaled_nodes["workers"].autoscaling_group_name
      DesiredCapacity      = 0
    }
    error_message = "the schedule must set the group's desired capacity to zero"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.nightly_stop[0].policy).Statement[1].Resource == [module.autoscaled_nodes["workers"].autoscaling_group_arn]
    error_message = "the schedule's role must be allowed to scale exactly this cluster's groups"
  }
}

run "the_stop_time_must_be_a_clock_time" {
  command = plan

  variables {
    nightly_stop = { time = "8pm", timezone = "Australia/Sydney" }
  }

  expect_failures = [var.nightly_stop]
}
