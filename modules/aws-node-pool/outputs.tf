# SPDX-License-Identifier: Apache-2.0
output "autoscaling_group_name" {
  description = "Name of the Auto Scaling group. Its instances are invisible to Terraform; find them through this."
  value       = aws_autoscaling_group.node.name
}

output "autoscaling_group_arn" {
  description = "ARN of the Auto Scaling group, for scoping policies that scale it."
  value       = aws_autoscaling_group.node.arn
}

output "launch_template_id" {
  description = "Launch template the group launches from."
  value       = aws_launch_template.node.id
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM)."
  value       = "aws"
}

output "subnet_id" {
  description = "Subnet the group launches into."
  value       = var.subnet_id
}

output "availability_zone" {
  description = "Availability zone of subnet_id."
  value       = local.availability_zone
}

output "node_arch" {
  description = "CPU architecture reported by AWS for instance_type."
  value       = local.ami_arch
}

output "node_iam_role_name" {
  description = "IAM role attached to every node in the group."
  value       = aws_iam_role.node.name
}

output "node_labels" {
  description = "Labels every node in the group carries."
  value       = local.node_labels
}

output "node_taints" {
  description = "Taints every node in the group carries."
  value       = var.node_taints
}
