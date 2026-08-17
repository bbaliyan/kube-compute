# SPDX-License-Identifier: Apache-2.0

output "cluster_name" {
  description = "Cluster name passed to the module."
  value       = module.control_plane.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID of the genesis control-plane instance."
  value       = module.control_plane.instance_id
}

output "cluster_ip" {
  description = "Genesis control-plane node's private IP."
  value       = module.control_plane.cluster_ip
}

output "cluster_fqdn" {
  description = "API server / kubeconfig FQDN, or null when no cluster_domain was given."
  value       = module.control_plane.cluster_fqdn
}

output "node_provider" {
  description = "Provider identifier ('aws')."
  value       = module.control_plane.node_provider
}

output "node_control_ref" {
  description = "Genesis instance ID, for control-plane verb-scripts that need a single node reference (SSM send-command/start-session)."
  value       = module.control_plane.node_control_ref
}

output "wildcard_dns_name" {
  description = "Wildcard hostname for cluster services, or null when no cluster_domain was given."
  value       = module.control_plane.wildcard_dns_name
}

output "aws_region" {
  description = "Region the cluster runs in (the verb-scripts need it for SSM calls)."
  value       = module.control_plane.aws_region
}

output "node_arch" {
  description = "CPU architecture reported by AWS for instance_type."
  value       = module.control_plane.node_arch
}

output "effective_ami_id" {
  description = "AMI ID actually used for the control-plane node(s) (explicit os_image_ami_id, an os_image_name lookup, or the AlmaLinux 10 data-lookup fallback)."
  value       = module.control_plane.effective_ami_id
}

output "vpc_id" {
  description = "VPC ID the control plane launched into."
  value       = module.control_plane.vpc_id
}

output "subnet_id" {
  description = "Subnet ID the genesis control-plane node launched into."
  value       = module.control_plane.subnet_id
}

output "node_iam_role_name" {
  description = "IAM role name attached to the control-plane node(s). Reference this in your consumer repo to attach additional policies (e.g. SSM Parameter Store read access for ESO)."
  value       = module.control_plane.node_iam_role_name
}

output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API."
  value       = module.control_plane.registration_address
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, provider}."
  value       = module.control_plane.control_plane_node_refs
}

output "cluster_security_group_id" {
  description = "Self-referencing security group id shared by every cluster member."
  value       = module.control_plane.cluster_security_group_id
}

output "agent_token_ssm_parameter" {
  description = "SSM Parameter Store name (SecureString) holding the agent join token."
  value       = module.control_plane.agent_token_ssm_parameter
}

output "node_pools" {
  description = "Map of pool name (matching var.node_pools' own keys) -> {node_provider, autoscaling_group_name, launch_template_id, availability_zone, worker_iam_role_name}, one entry per configured pool. Empty map when var.node_pools is empty. No worker_node_refs (unlike proxmox-cluster's node_pools output): the ASG creates instances directly from the launch template, so Terraform never sees individual pool members — see this module's README for what that means for node-os-patch."
  value = {
    for name, pool in module.node_pools : name => {
      node_provider          = pool.node_provider
      autoscaling_group_name = pool.autoscaling_group_name
      launch_template_id     = pool.launch_template_id
      availability_zone      = pool.availability_zone
      worker_iam_role_name   = pool.worker_iam_role_name
    }
  }
}
