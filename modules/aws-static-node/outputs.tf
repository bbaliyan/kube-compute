# SPDX-License-Identifier: Apache-2.0

output "node_refs" {
  description = "Map of Kubernetes node name -> {instance_id, provider}, one entry per node in this group. Same shape as aws-control-plane's control_plane_node_refs, so anything that already targets control-plane nodes by that shape (SSM send-command, a patch verb) takes workers without a second code path. This is the output an ASG cannot produce."
  value = {
    for k, inst in aws_instance.node :
    local.node_names[k] => {
      instance_id = inst.id
      provider    = "aws"
    }
  }
}

output "instance_ids" {
  description = "Flat list of this group's EC2 instance ids. Consumed by a stop schedule, whose IAM policy is written against instance ARNs and therefore needs ids that survive a reboot."
  value       = [for k in sort(keys(aws_instance.node)) : aws_instance.node[k].id]
}

output "private_ips" {
  description = "Map of Kubernetes node name -> private IP."
  value       = { for k, inst in aws_instance.node : local.node_names[k] => inst.private_ip }
}

output "node_provider" {
  description = "Provider identifier the control-plane verb-scripts use to dispatch (AWS = SSM)."
  value       = "aws"
}

output "availability_zone" {
  description = "Availability zone this group is pinned to, derived from subnet_id."
  value       = local.availability_zone
}

output "node_arch" {
  description = "CPU architecture AWS reports for instance_type, and therefore the architecture the AMI lookup filtered on."
  value       = local.ami_arch
}

output "effective_ami_id" {
  description = "AMI ID actually used (explicit os_image_ami_id, an os_image_name lookup, or the AlmaLinux 10 fallback)."
  value       = local.effective_ami_id
}

output "node_iam_role_name" {
  description = "IAM role name attached to every node in this group. Reference it to attach additional policies (e.g. an S3 grant for a workload that only runs here)."
  value       = aws_iam_role.node.name
}

output "node_labels" {
  description = "The full label set applied at rke2 install time, including the AZ label and the kube-compute.io/node-group label this module sets itself. Exposed so a consumer can build a matching nodeSelector without restating them."
  value       = local.node_labels
}

output "node_taints" {
  description = "The taints applied at rke2 install time. Exposed so a consumer can build matching tolerations without restating them."
  value       = var.node_taints
}

output "subnet_id" {
  description = "Subnet every node in this group launched into. Exposed so a composing module can assert the group actually inherited the control plane's subnet rather than drifting into another availability zone, which would strand its EBS volumes."
  value       = var.subnet_id
}
