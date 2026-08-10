# SPDX-License-Identifier: Apache-2.0
output "autoscaling_group_name" {
  description = "Name of the fixed-size ASG backing this pool. Terraform never sees individual pool members (the ASG creates them directly from the launch template), so instance discovery for the control-plane verb-scripts/SSM targeting goes through this name (e.g. 'aws autoscaling describe-auto-scaling-groups' or 'aws ec2 describe-instances --filters tag:aws:autoscaling:groupName=<this>'), not a Terraform-visible instance id list."
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
