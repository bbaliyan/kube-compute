# SPDX-License-Identifier: Apache-2.0

mock_provider "aws" {
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/kube-compute-bharat-stop" }
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

run "off_by_default_stops_nothing" {
  command = plan

  assert {
    condition     = length(aws_scheduler_schedule.nightly_stop) == 0 && !can(local.autoscaler_platform_helm_parameters.nightScaleDownEnabled)
    error_message = "without nightly_stop nothing may stop the nodes or scale the workers down"
  }
}

run "a_cluster_without_autoscaling_only_stops_its_nodes" {
  command = plan

  variables {
    nightly_stop = { time = "20:00", timezone = "Australia/Sydney" }
  }

  assert {
    condition     = aws_scheduler_schedule.nightly_stop[0].schedule_expression == "cron(0 20 * * ? *)"
    error_message = "the stop must fire at nightly_stop.time"
  }
  assert {
    condition     = !can(local.autoscaler_platform_helm_parameters.nightScaleDownEnabled)
    error_message = "there are no MachineDeployments to scale down without autoscaling"
  }
}

run "an_autoscaled_cluster_scales_down_before_and_resumes_after_the_stop" {
  command = plan

  variables {
    nightly_stop               = { time = "00:02", timezone = "Europe/London" }
    cluster_domain             = "eu-west-1.example.net"
    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_groups = {
      workers = { instance_type = "t3a.large", max_size = 2 }
    }
  }

  assert {
    condition     = aws_scheduler_schedule.nightly_stop[0].schedule_expression == "cron(2 0 * * ? *)"
    error_message = "the stop must fire at nightly_stop.time"
  }
  assert {
    condition = (
      local.autoscaler_platform_helm_parameters.nightScaleDownEnabled == "true" &&
      local.autoscaler_platform_helm_parameters.nightScaleDownSchedule == "57 23 * * *" &&
      local.autoscaler_platform_helm_parameters.nightResumeSchedule == "32 0 * * *" &&
      local.autoscaler_platform_helm_parameters.nightScaleDownTimeZone == "Europe/London"
    )
    error_message = "the scale-down must run five minutes before the stop and the resume 30 minutes after it, across midnight, in the stop's timezone"
  }
}

run "the_stop_time_must_be_a_clock_time" {
  command = plan

  variables {
    nightly_stop = { time = "8pm", timezone = "Australia/Sydney" }
  }

  expect_failures = [var.nightly_stop]
}

run "night_scale_down_cannot_be_configured_separately" {
  command = plan

  variables {
    platform_extra_helm_parameters = { nightScaleDownEnabled = "true" }
  }

  expect_failures = [terraform_data.night_scale_down_is_derived]
}
