# SPDX-License-Identifier: Apache-2.0
output "instance_ids" {
  description = "EC2 instance IDs of every worker in this pool, in index order. Control-plane verb-scripts target these via SSM (aws ssm send-command/start-session)."
  value       = aws_instance.worker[*].id
}

output "private_ips" {
  description = "Private IPv4 address of every worker in this pool, in index order."
  value       = aws_instance.worker[*].private_ip
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
