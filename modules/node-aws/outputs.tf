# SPDX-License-Identifier: Apache-2.0

# ---- Standardized outputs (identical names across all provider modules) ----

output "cluster_name" {
  description = "Cluster name passed to the module. Use this to name local kubeconfig files and other client-side resources."
  value       = var.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID."
  value       = aws_instance.node.id
}

output "cluster_ip" {
  description = "Private IP of the K3s node. Register your DNS wildcard at this address."
  value       = aws_instance.node.private_ip
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given (IP-only)."
  value       = local.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM)."
  value       = "aws"
}

output "bootstrap_status_ref" {
  description = "Handle the control-plane uses to read bootstrap status/kubeconfig. For AWS: the instance ID, targeted via 'aws ssm send-command' in region aws_region."
  value       = aws_instance.node.id
}

# ---- DNS support: register this yourself if you didn't pass a hosted_zone_id ----
output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services (e.g. *.bharat.example.internal), or null when no cluster_domain was given. Point this at cluster_ip in your DNS of choice."
  value       = local.wildcard_name
}

# ---- Useful AWS extras ----
output "aws_region" {
  description = "Region the node runs in (the verb-scripts need it for SSM calls)."
  value       = var.aws_region
}

output "node_arch" {
  description = "CPU architecture reported by AWS for the instance type (arm64 or x86_64)."
  value       = local.ami_arch
}

output "effective_ami_id" {
  description = "AMI ID used (explicit override or AL2023 lookup)."
  value       = local.effective_ami_id
}

output "vpc_id" {
  description = "VPC ID the node launched into (derived from the subnet)."
  value       = data.aws_subnet.selected.vpc_id
}

output "subnet_id" {
  description = "Subnet ID the node launched into (given or default-VPC fallback)."
  value       = local.effective_subnet_id
}

output "node_iam_role_name" {
  description = "IAM role name attached to the node. Reference this in your consumer repo to attach additional policies (e.g. SSM Parameter Store read access for ESO)."
  value       = aws_iam_role.node.name
}
