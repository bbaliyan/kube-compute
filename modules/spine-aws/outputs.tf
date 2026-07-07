# SPDX-License-Identifier: Apache-2.0

# ---- Standardized outputs (identical names across all provider modules) ----

output "cluster_name" {
  description = "Cluster name passed to the module. Use this to name local kubeconfig files and other client-side resources."
  value       = var.cluster_name
}

output "instance_id" {
  description = "Provider-native node ID."
  value       = aws_instance.control_plane.id
}

output "cluster_ip" {
  description = "Private IP of the K3s node. Register your DNS wildcard at this address."
  value       = aws_instance.control_plane.private_ip
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
  value       = aws_instance.control_plane.id
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
  description = "VPC ID the control plane launched into (derived from the subnet — the single-node subnet_id/subnet_name/default-VPC fallback for control_plane_count = 1, or the control-plane subnets themselves for control_plane_count > 1)."
  value       = local.module_vpc_id
}

output "subnet_id" {
  description = "Subnet ID the node launched into (given or default-VPC fallback)."
  value       = local.effective_subnet_id
}

output "node_iam_role_name" {
  description = "IAM role name attached to the node. Reference this in your consumer repo to attach additional policies (e.g. SSM Parameter Store read access for ESO)."
  value       = aws_iam_role.node.name
}

# ---- Join flow: consumed by worker-pool-aws (and, later, additional control-plane nodes) ----
output "registration_address" {
  description = "Address workers/joining servers use to reach the cluster API. For control_plane_count = 1, this is the sole control-plane node's private IP. For control_plane_count > 1, it depends on endpoint_mode: the internal NLB's DNS name (loadbalancer, default), the shared Route53 record name (dns), or static_registration_address verbatim (static)."
  value       = local.registration_address != null ? local.registration_address : aws_instance.control_plane.private_ip
}

output "agent_token_ssm_parameter" {
  description = "SSM Parameter Store name (SecureString) holding the agent join token. Fetch it at boot via the instance IAM role — never embed it in user_data or a launch template."
  value       = aws_ssm_parameter.agent_token.name
}

output "cluster_security_group_id" {
  description = "Self-referencing security group id shared by every cluster member (control-plane and worker pools). Worker-pool modules attach to this by id; it is never provided to anything outside the cluster."
  value       = aws_security_group.cluster.id
}

output "control_plane_node_refs" {
  description = "Map of control-plane node name -> {instance_id, provider}. The control-plane abstraction (SSM send-command today) targets every node from this map instead of a single bootstrap_status_ref."
  value = merge(
    {
      "${var.cluster_name}-cp-1" = {
        instance_id = aws_instance.control_plane.id
        provider    = "aws"
      }
    },
    {
      for i, inst in aws_instance.control_plane_additional :
      "${var.cluster_name}-cp-${tonumber(i) + 1}" => {
        instance_id = inst.id
        provider    = "aws"
      }
    }
  )
}

output "rendered_cloud_init" {
  description = "Plaintext rendered cloud-config passed through from cloud-init. Sensitive — contains the cluster/agent tokens. Exposed for tests and debugging only; not part of the module's operational interface."
  value       = module.bootstrap.cloud_init
  sensitive   = true
}

output "rendered_cloud_init_additional" {
  description = "Map of rendered cloud-config for additional control-plane nodes, keyed by index (1..N). Sensitive — contains the cluster/agent tokens. Exposed for tests and debugging only."
  value = {
    for idx, m in module.bootstrap_additional :
    idx => m.cloud_init
  }
  sensitive = true
}
