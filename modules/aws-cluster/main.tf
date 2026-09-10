# SPDX-License-Identifier: Apache-2.0

# Every EC2 instance in this cluster that Terraform owns individually: the control-plane
# node(s) plus every static node group's instances. Nothing from var.node_pools appears here,
# because an autoscaling group creates its members directly from the launch template and
# Terraform never sees them.
#
# Deliberately a local as well as an output. A consumer that generates an extra .tf file into
# this module's directory (terragrunt's generate block does exactly that, for a nightly stop
# schedule) cannot reference the module's own outputs, only its locals and module calls -- and
# recomputing this list at that end would put the same concat in two places, where one of them
# would eventually be forgotten when a new kind of node appears.
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

# Named instances rather than an autoscaling group; see modules/aws-static-node/README.md
# for why that is the right way round on a cluster that stops overnight.
#
# subnet_id falls back to the control plane's own resolved subnet, so a group lands in the
# control plane's availability zone by construction instead of being pointed at a subnet by
# hand. An EBS volume cannot cross zones, so a worker in the wrong one cannot mount the data
# it was created for.
#
# cluster_fqdn_suffix is not exposed as a variable on this module: aws-control-plane derives
# it from cluster_name and cluster_domain, so recomputing it here keeps the two in step
# without a second input that could disagree with the first.
module "static_nodes" {
  source   = "../aws-static-node"
  for_each = var.static_nodes

  cluster_name              = var.cluster_name
  group_name                = each.key
  aws_region                = var.aws_region
  registration_address      = module.control_plane.registration_address
  agent_token_ssm_parameter = module.control_plane.agent_token_ssm_parameter
  cluster_fqdn_suffix       = var.cluster_domain != null ? "${var.cluster_name}.${var.cluster_domain}" : null

  # The ingress security group is opt-in per group: it carries this cluster's externally
  # reachable ports, and only the group actually running the ingress controller should answer
  # on them.
  security_group_ids = concat(
    [module.control_plane.cluster_security_group_id],
    each.value.attach_ingress_sg ? [module.control_plane.node_security_group_id] : [],
  )

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

  # Cluster-wide by default, overridable per group: a worker that cannot verify the corp CA
  # or reach the registry mirror cannot pull an image, and a worker with the control plane's
  # resolver list avoids the wildcard-search-domain trap identically.
  trusted_ca_pem      = each.value.trusted_ca_pem != null ? each.value.trusted_ca_pem : var.trusted_ca_pem
  registry_mirror_url = each.value.registry_mirror_url != null ? each.value.registry_mirror_url : var.registry_mirror_url
  dns_servers         = each.value.dns_servers != null ? each.value.dns_servers : var.dns_servers
  extra_tags          = merge(var.extra_tags, each.value.extra_tags)
}
