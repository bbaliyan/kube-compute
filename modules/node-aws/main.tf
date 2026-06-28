# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../node-bootstrap/templates/cloud-init-al2023.yaml.tpl")

  # Arch from AWS's own metadata — covers all present and future instance types.
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  effective_ami_id = var.os_image_ami_id != null ? var.os_image_ami_id : one(data.aws_ami.al2023[*].id)

  # Network handle: the given subnet, else the first subnet in the default VPC. Never creates fabric.
  effective_subnet_id = coalesce(var.subnet_id, try(sort(data.aws_subnets.default[0].ids)[0], null))

  # DNS is optional and name-only. cluster_fqdn is the API/kubeconfig name; wildcard covers it + services.
  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  create_record = local.has_domain && var.hosted_zone_id != null

  common_tags = {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-node"
  }
}

module "bootstrap" {
  source = "../node-bootstrap"

  cloud_init_template       = local.cloud_init_template
  cluster_name              = var.cluster_name
  k8s_version               = var.k8s_version
  cluster_fqdn              = local.cluster_fqdn
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  gitops_platform_repo_url  = var.gitops_platform_repo_url
  gitops_platform_revision  = var.gitops_platform_revision
  gitops_workloads_repo_url = var.gitops_workloads_repo_url
  gitops_workloads_revision = var.gitops_workloads_revision
  gitops_workloads_path     = var.gitops_workloads_path
  cert_mode                 = var.cert_mode
}

# ---- Module-owned security group (NOT fabric) ----
resource "aws_security_group" "node" {
  name_prefix = "kube-node-${var.cluster_name}-"
  description = "kube-node ${var.cluster_name}: cluster access ports only, no SSH."
  vpc_id      = data.aws_subnet.selected.vpc_id
  tags        = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}" })

  lifecycle {
    # create_before_destroy avoids a name_prefix collision when the SG is replaced. The
    # instance's SG re-association is a separate apply step, so this is not zero-downtime —
    # acceptable for disposable dev clusters.
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "node" {
  for_each = { for p in var.ingress_ports : tostring(p) => p }

  security_group_id = aws_security_group.node.id
  description       = "cluster access port ${each.value}"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  # One rule per port spanning the first allowed CIDR; remaining CIDRs handled below.
  cidr_ipv4 = var.allowed_ingress_cidrs[0]
}

# Additional CIDRs beyond the first, per port.
resource "aws_vpc_security_group_ingress_rule" "node_extra" {
  for_each = {
    for pair in setproduct(var.ingress_ports, slice(var.allowed_ingress_cidrs, 1, length(var.allowed_ingress_cidrs))) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.node.id
  description       = "cluster access port ${each.value.port}"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- IAM: SSM-managed instance for the control-plane (send-command/session) ----
# Inline JSON avoids a data.aws_iam_policy_document block that mock_provider cannot evaluate.
resource "aws_iam_role" "node" {
  name_prefix = "kube-node-${var.cluster_name}-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "kube-node-${var.cluster_name}-"
  role        = aws_iam_role.node.name
  tags        = local.common_tags
}

# ---- The EC2 node ----
resource "aws_instance" "node" {
  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = local.effective_subnet_id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 2          # lets pods reach IMDS for instance-profile auth
  }

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-root" })
  }

  user_data_base64            = module.bootstrap.user_data_base64
  user_data_replace_on_change = true # disposable nodes: replace on bootstrap change

  tags = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}" })

  lifecycle {
    # Don't replace on AL2023 AMI patch drift; remove to deliberately upgrade.
    ignore_changes = [ami]
  }
}

# ---- Optional DNS convenience: wildcard A record in a Route53 zone you already own ----
# Created ONLY when both cluster_domain and hosted_zone_id are set. Otherwise the module owns no DNS;
# register *.${cluster}.${domain} -> cluster_ip in your DNS of choice using the wildcard_dns_name output.
resource "aws_route53_record" "wildcard" {
  count   = local.create_record ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = local.wildcard_name
  type    = "A"
  ttl     = 60
  records = [aws_instance.node.private_ip]
}
