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
  workloads_helm_values_object      = var.workloads_helm_values_object
  cluster_type                      = var.cluster_type
  cni                               = var.cni
  cert_mode                         = var.cert_mode
  platform_extra_helm_parameters    = local.autoscaler_platform_helm_parameters
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
  manage_wildcard_dns_record        = var.manage_wildcard_dns_record
  hosted_zone_name                  = var.hosted_zone_name
  hosted_zone_id                    = var.hosted_zone_id
  instance_type                     = var.instance_type
  os_image_ami_id                   = var.os_image_ami_id
  os_image_name                     = var.os_image_name
  allowed_ingress_cidrs             = var.allowed_ingress_cidrs
  ingress_ports                     = var.ingress_ports
  root_volume_size_gb               = var.root_volume_size_gb
  root_volume_type                  = var.root_volume_type

  genesis_apply_manifests             = local.cluster_autoscaler_genesis_manifests
  cluster_autoscaler_crd_wait_enabled = var.cluster_autoscaler_enabled
  # This project's AWS image stages no capi-install.yaml, so bootstrap.sh waits
  # for the CRDs the platform Application installs rather than applying any.
  cluster_autoscaler_capi_install_baked = false
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

# ---- Cluster API autoscaling (Phase 2) ----
#
# Mirrors proxmox-cluster's shape: the same enabled flag, min/max sizes and machine
# template, delivered through node-bootstrap's genesis_apply_manifests. The one
# structural difference is where Cluster API itself comes from -- the Proxmox VM
# template stages a clusterctl-generated install manifest and the AWS image does
# not, so here it arrives as a platform Argo CD Application and bootstrap.sh waits
# for its CRDs instead of applying them.
locals {
  autoscaler_common_tags               = merge(var.extra_tags, { ClusterName = var.cluster_name, ManagedBy = "kube-compute" })
  autoscaler_agent_token_fetch_command = "aws ssm get-parameter --name '${module.control_plane.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  # Deliberately NOT module.control_plane.registration_address, which resolves
  # from the control-plane instance: this bundle is written INTO that instance's
  # own cloud-init, so referencing it is a dependency cycle. Confirmed as one --
  # the same cycle proxmox-cluster's equivalent local documents.
  #
  # Derived from variables only. api.<cluster>.<domain> is answered by the
  # wildcard Route53 record aws-control-plane creates, which for a single control
  # plane has exactly one target, so this is a single-target name rather than the
  # round-robin one that causes long join hangs on the Proxmox side.
  autoscaler_registration_address = var.cluster_domain != null ? "api.${var.cluster_name}.${var.cluster_domain}" : null

  autoscaler_groups = var.cluster_autoscaler_enabled ? var.cluster_autoscaler_worker_groups : {}

  # An IAM name_prefix caps at 38 characters, and this one carries two fixed
  # affixes worth 19 of them. The cluster name is what gets truncated, so
  # "-capi-" survives: it is what distinguishes these from the control-plane
  # role at a glance in the console, and AWS appends its own unique suffix
  # anyway. Truncating avoids failing at apply time on a long cluster name,
  # after everything else in the plan has already been created.
  autoscaler_role_name_prefix = format("kube-compute-%s-capi-", substr(var.cluster_name, 0, 19))

  autoscaler_group_arch = {
    for name, g in local.autoscaler_groups :
    name => contains(data.aws_ec2_instance_type.autoscaler_worker[name].supported_architectures, "arm64") ? "arm64" : "x86_64"
  }

  autoscaler_group_ami = {
    for name, g in local.autoscaler_groups :
    name => g.os_image_ami_id != null ? g.os_image_ami_id : (
      var.os_image_name != null ? data.aws_ami.autoscaler_worker[name].id : module.control_plane.effective_ami_id
    )
  }

  # Carried on the node itself, not just the security group, so external-dns can
  # select the nodes that actually serve ingress. The two travel together: a node
  # with the group has the label, and nothing else does.
  autoscaler_group_labels = {
    for name, g in local.autoscaler_groups : name => merge(
      g.node_labels,
      { "kube-compute.io/node-group" = name },
      g.attach_ingress_sg ? { "kube-compute.io/ingress" = "true" } : {},
    )
  }

  # cluster-autoscaler simulates a scale from zero against these, since nothing
  # reports a group's shape while it has no nodes. Read from AWS rather than
  # restated by the caller, which would be a second place to get it wrong.
  autoscaler_group_render = {
    for name, g in local.autoscaler_groups : name => {
      name                = name
      instance_type       = g.instance_type
      min_size            = g.min_size
      max_size            = g.max_size
      root_volume_size_gb = g.root_volume_size_gb
      root_volume_type    = g.root_volume_type
      ami_id              = local.autoscaler_group_ami[name]
      cpu                 = data.aws_ec2_instance_type.autoscaler_worker[name].default_vcpus
      memory_mib          = data.aws_ec2_instance_type.autoscaler_worker[name].memory_size
      labels              = local.autoscaler_group_labels[name]
      taints              = g.node_taints
      security_group_ids = concat(
        [module.control_plane.cluster_security_group_id],
        g.attach_ingress_sg ? [module.control_plane.node_security_group_id] : [],
      )
      bootstrap_secret_b64 = base64encode(module.cluster_autoscaler_worker_bootstrap[name].cloud_init_user_data)
    }
  }

  cluster_autoscaler_bundle_yaml = !var.cluster_autoscaler_enabled ? "" : templatefile(
    "${path.module}/templates/cluster-autoscaler-workers.yaml.tftpl",
    {
      cluster_name         = var.cluster_name
      aws_region           = var.aws_region
      worker_groups        = local.autoscaler_group_render
      iam_instance_profile = try(aws_iam_instance_profile.autoscaler_worker[0].name, "")
      vpc_id               = module.control_plane.vpc_id
      subnet_id            = module.control_plane.subnet_id
      # Never consulted for anything actionable -- the AWSCluster is a placeholder
      # to satisfy CAPA's Get -- but the CRD rejects an empty host, which is how
      # the Proxmox equivalent found out.
      control_plane_endpoint_host = local.autoscaler_registration_address != null ? local.autoscaler_registration_address : ""
      control_plane_endpoint_port = 6443
    }
  )

  cluster_autoscaler_genesis_manifests = !var.cluster_autoscaler_enabled ? [] : [{
    path    = "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    content = local.cluster_autoscaler_bundle_yaml
  }]

  # kube-platform gates both Applications on these. This module owns the decision,
  # so it injects them through the generic parameter map rather than
  # aws-control-plane growing two dedicated inputs.
  autoscaler_platform_helm_parameters = merge(
    var.platform_extra_helm_parameters,
    var.cluster_autoscaler_enabled ? {
      clusterAutoscalerEnabled = "true"
      clusterApiEnabled        = "true"
    } : {},
    # Turned on by the same decision that turns the Terraform record off, so the
    # two cannot disagree and leave the wildcard owned by nobody.
    var.manage_wildcard_dns_record ? {} : { externalDnsEnabled = "true" },
  )
}

# A module call cannot carry a lifecycle precondition and a check block only warns,
# so this exists purely to fail the apply rather than bake a null join address into
# every autoscaled worker's Secret. Same device, and the same reason, as
# proxmox-cluster's own terraform_data guard.
resource "terraform_data" "autoscaler_registration_address_configured" {
  count = var.cluster_autoscaler_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.autoscaler_registration_address != null
      error_message = "cluster_autoscaler_enabled = true requires cluster_domain to be set: autoscaled workers join through api.<cluster_name>.<cluster_domain>, which cannot be the control plane's own IP without a dependency cycle."
    }
  }
}

# The CAPI manifests apply Issuer/Certificate objects, which only exist once
# cert-manager does -- and cert-manager arrives with the platform Application.
resource "terraform_data" "autoscaler_requires_platform_gitops" {
  count = var.cluster_autoscaler_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.gitops_platform_enabled
      error_message = "cluster_autoscaler_enabled = true requires gitops_platform_enabled = true -- Cluster API is installed by the platform Argo CD Application, and its webhooks depend on cert-manager, which the same Application installs."
    }
  }
}

# One shared render for every CAPI-provisioned replica, referenced by the
# MachineDeployment through a single Secret. set_hostname = false because the
# payload is byte-identical across replicas and so cannot carry a unique hostname;
# CAPA's own cloud-init metadata supplies one instead.
module "cluster_autoscaler_worker_bootstrap" {
  source   = "../node-bootstrap"
  for_each = local.autoscaler_groups

  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-${each.key}"
  node_role                 = "worker"
  set_hostname              = false
  node_labels               = local.autoscaler_group_labels[each.key]
  node_taints               = each.value.node_taints
  registration_address      = local.autoscaler_registration_address
  agent_token_fetch_command = local.autoscaler_agent_token_fetch_command
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  dns_servers               = var.dns_servers
}

# CAPA does not create an instance profile when the cluster is externally managed,
# and AWSMachineTemplate takes a profile name that must already exist.
resource "aws_iam_role" "autoscaler_worker" {
  count       = var.cluster_autoscaler_enabled ? 1 : 0
  name_prefix = local.autoscaler_role_name_prefix
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.autoscaler_common_tags
}

resource "aws_iam_role_policy_attachment" "autoscaler_worker_ssm_core" {
  count      = var.cluster_autoscaler_enabled ? 1 : 0
  role       = aws_iam_role.autoscaler_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "autoscaler_worker_ebs_csi" {
  count      = var.cluster_autoscaler_enabled ? 1 : 0
  role       = aws_iam_role.autoscaler_worker[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "autoscaler_worker_agent_token" {
  count = var.cluster_autoscaler_enabled ? 1 : 0
  name  = "kube-compute-${var.cluster_name}-capi-agent-token-read"
  role  = aws_iam_role.autoscaler_worker[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.kube_compute.account_id}:parameter${module.control_plane.agent_token_ssm_parameter}"
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "autoscaler_worker" {
  count       = var.cluster_autoscaler_enabled ? 1 : 0
  name_prefix = local.autoscaler_role_name_prefix
  role        = aws_iam_role.autoscaler_worker[0].name
  tags        = local.autoscaler_common_tags
}
