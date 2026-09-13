# SPDX-License-Identifier: Apache-2.0

locals {
  nightly_stop_minute_of_day = try(tonumber(split(":", var.nightly_stop.time)[0]) * 60 + tonumber(split(":", var.nightly_stop.time)[1]), 0)
  nightly_scale_down_minute  = (local.nightly_stop_minute_of_day + 1440 - 5) % 1440
  nightly_resume_minute      = (local.nightly_stop_minute_of_day + 30) % 1440

  nightly_stop_platform_parameters = var.nightly_stop != null && var.cluster_autoscaler_enabled ? {
    nightScaleDownEnabled  = "true"
    nightScaleDownSchedule = format("%d %d * * *", local.nightly_scale_down_minute % 60, floor(local.nightly_scale_down_minute / 60))
    nightResumeSchedule    = format("%d %d * * *", local.nightly_resume_minute % 60, floor(local.nightly_resume_minute / 60))
    nightScaleDownTimeZone = try(var.nightly_stop.timezone, "")
  } : {}
}

resource "terraform_data" "night_scale_down_is_derived" {
  lifecycle {
    precondition {
      condition     = alltrue([for key in keys(var.platform_extra_helm_parameters) : !startswith(key, "nightScaleDown") && key != "nightResumeSchedule"])
      error_message = "Set nightly_stop instead of the night scale-down platform parameters: the scale-down, the resume and the stop are derived from it together."
    }
  }
}

resource "aws_iam_role" "nightly_stop" {
  count       = var.nightly_stop == null ? 0 : 1
  name_prefix = format("kube-compute-%s-stop-", substr(var.cluster_name, 0, 19))

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.extra_tags, { ClusterName = var.cluster_name, ManagedBy = "kube-compute" })
}

resource "aws_iam_role_policy" "nightly_stop" {
  count = var.nightly_stop == null ? 0 : 1
  name  = "stop-instances"
  role  = aws_iam_role.nightly_stop[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:StopInstances"
      Resource = [for id in local.all_instance_ids : "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.kube_compute.account_id}:instance/${id}"]
    }]
  })
}

resource "aws_scheduler_schedule" "nightly_stop" {
  count = var.nightly_stop == null ? 0 : 1
  name  = "${var.cluster_name}-node-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = format("cron(%d %d * * ? *)", local.nightly_stop_minute_of_day % 60, floor(local.nightly_stop_minute_of_day / 60))
  schedule_expression_timezone = var.nightly_stop.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.nightly_stop[0].arn

    input = jsonencode({
      InstanceIds = local.all_instance_ids
    })
  }
}
