# SPDX-License-Identifier: Apache-2.0

# A local as well as an output: generated .tf files (terragrunt's generate block, for the
# stop schedule) can reference a module's locals but not its outputs.
locals {
  all_instance_ids = concat(
    [for name, ref in module.control_plane.control_plane_node_refs : ref.instance_id],
    flatten([for name, group in module.static_nodes : group.instance_ids]),
  )
}

module "control_plane" {
  source = "../aws-control-plane"

  cluster_name                      = var.cluster_name
  trusted_ca_pem                    = var.trusted_ca_pem
  registry_mirror_url               = var.registry_mirror_url
  dns_servers                       = var.dns_servers
  gitops_platform_enabled           = var.gitops_platform_enabled
  gitops_platform_repo_url_override = var.gitops_platform_repo_url_override
  gitops_platform_revision_override = var.gitops_platform_revision_override
  gitops_workloads_repo_url         = var.gitops_workloads_repo_url
  gitops_workloads_revision         = var.gitops_workloads_revision
  gitops_workloads_path             = var.gitops_workloads_path
  workloads_extra_helm_parameters   = var.workloads_extra_helm_parameters
  cluster_type                      = var.cluster_type
  cni                               = var.cni
  cert_mode                         = var.cert_mode
  platform_extra_helm_parameters    = var.platform_extra_helm_parameters
  platform_helm_values_object       = var.platform_helm_values_object
  extra_tags                        = var.extra_tags
  aws_region                        = var.aws_region
  control_plane_count               = var.control_plane_count
  control_plane_subnets             = var.control_plane_subnets
  endpoint_mode                     = var.endpoint_mode
  static_registration_address       = var.static_registration_address
  subnet_id                         = var.subnet_id
  vpc_name                          = var.vpc_name
  subnet_name                       = var.subnet_name
  subnet_names                      = var.subnet_names
  cluster_domain                    = var.cluster_domain
  hosted_zone_name                  = var.hosted_zone_name
  hosted_zone_id                    = var.hosted_zone_id
  instance_type                     = var.instance_type
  os_image_ami_id                   = var.os_image_ami_id
  os_image_name                     = var.os_image_name
  allowed_ingress_cidrs             = var.allowed_ingress_cidrs
  ingress_ports                     = var.ingress_ports
  root_volume_size_gb               = var.root_volume_size_gb
  root_volume_type                  = var.root_volume_type
}

module "node_pools" {
  source   = "../aws-node-pool"
  for_each = var.node_pools

  cluster_name              = var.cluster_name
  aws_region                = var.aws_region
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  cluster_security_group_id = module.control_plane.cluster_security_group_id

  trusted_ca_pem      = each.value.trusted_ca_pem
  registry_mirror_url = each.value.registry_mirror_url
  dns_servers         = each.value.dns_servers
  subnet_id           = each.value.subnet_id
  desired_count       = each.value.desired_count
  instance_type       = each.value.instance_type
  os_image_ami_id     = each.value.os_image_ami_id
  os_image_name       = each.value.os_image_name
  root_volume_size_gb = each.value.root_volume_size_gb
  root_volume_type    = each.value.root_volume_type
  extra_node_labels   = each.value.extra_node_labels
  extra_tags          = each.value.extra_tags
}

# See modules/aws-static-node/README.md for why named instances beat an ASG here.
module "static_nodes" {
  source   = "../aws-static-node"
  for_each = var.static_nodes

  cluster_name              = var.cluster_name
  group_name                = each.key
  aws_region                = var.aws_region
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  cluster_fqdn_suffix       = var.cluster_domain != null ? "${var.cluster_name}.${var.cluster_domain}" : null

  # Opt-in per group: only the group running the ingress controller should answer on this
  # cluster's externally reachable ports.
  security_group_ids = concat(
    [module.control_plane.cluster_security_group_id],
    each.value.attach_ingress_sg ? [module.control_plane.node_security_group_id] : [],
  )

  # Defaults to the control plane's own subnet, so a group inherits its availability zone.
  # An EBS volume cannot cross zones, so a worker in another one cannot mount its data.
  subnet_id             = coalesce(each.value.subnet_id, module.control_plane.subnet_id)
  node_count            = each.value.node_count
  instance_type         = each.value.instance_type
  os_image_ami_id       = each.value.os_image_ami_id
  os_image_name         = each.value.os_image_name != null ? each.value.os_image_name : var.os_image_name
  root_volume_size_gb   = each.value.root_volume_size_gb
  root_volume_type      = each.value.root_volume_type
  node_labels           = each.value.node_labels
  node_taints           = each.value.node_taints
  attach_ebs_csi_policy = each.value.attach_ebs_csi_policy

  # Cluster-wide by default, overridable per group. A ternary rather than coalesce(): all
  # three are commonly null on both sides, and coalesce raises when every argument is null.
  trusted_ca_pem      = each.value.trusted_ca_pem != null ? each.value.trusted_ca_pem : var.trusted_ca_pem
  registry_mirror_url = each.value.registry_mirror_url != null ? each.value.registry_mirror_url : var.registry_mirror_url
  dns_servers         = each.value.dns_servers != null ? each.value.dns_servers : var.dns_servers
  extra_tags          = merge(var.extra_tags, each.value.extra_tags)
}
