# SPDX-License-Identifier: Apache-2.0
output "autoscaling_group_name" {
  description = "Name of the ASG backing this pool."
  value       = aws_autoscaling_group.worker.name
}

output "launch_template_id" {
  description = "Launch template id used by the ASG."
  value       = aws_launch_template.worker.id
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM)."
  value       = "aws"
}

output "availability_zone" {
  description = "Availability zone this pool is pinned to (derived from subnet_id)."
  value       = local.availability_zone
}

output "worker_iam_role_name" {
  description = "IAM role name attached to every worker instance in this pool."
  value       = aws_iam_role.worker.name
}
