# SPDX-License-Identifier: Apache-2.0

locals {
  nightly_stop_minute_of_day = try(tonumber(split(":", var.nightly_stop.time)[0]) * 60 + tonumber(split(":", var.nightly_stop.time)[1]), 0)
  nightly_stop_expression    = format("cron(%d %d * * ? *)", local.nightly_stop_minute_of_day % 60, floor(local.nightly_stop_minute_of_day / 60))
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
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = "ec2:StopInstances"
        Resource = [for id in local.all_instance_ids : "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.kube_compute.account_id}:instance/${id}"]
      }],
      local.autoscaling_enabled ? [{
        Effect   = "Allow"
        Action   = "autoscaling:SetDesiredCapacity"
        Resource = [for group in module.autoscaled_nodes : group.autoscaling_group_arn]
      }] : [],
    )
  })
}

resource "aws_scheduler_schedule" "nightly_stop" {
  count = var.nightly_stop == null ? 0 : 1
  name  = "${var.cluster_name}-node-stop"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.nightly_stop_expression
  schedule_expression_timezone = var.nightly_stop.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.nightly_stop[0].arn

    input = jsonencode({
      InstanceIds = local.all_instance_ids
    })
  }
}

# Autoscaled nodes cannot be stopped, only removed. With the control plane stopping at
# the same moment, nothing is left running to scale them back up.
resource "aws_scheduler_schedule" "nightly_scale_to_zero" {
  for_each = var.nightly_stop == null ? {} : var.autoscaled_nodes
  name     = "${var.cluster_name}-${each.key}-to-zero"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = local.nightly_stop_expression
  schedule_expression_timezone = var.nightly_stop.timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:autoscaling:setDesiredCapacity"
    role_arn = aws_iam_role.nightly_stop[0].arn

    input = jsonencode({
      AutoScalingGroupName = module.autoscaled_nodes[each.key].autoscaling_group_name
      DesiredCapacity      = 0
    })
  }
}
