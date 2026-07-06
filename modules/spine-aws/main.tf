# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../node-bootstrap/templates/cloud-init-al2023.yaml.tpl")

  # Arch from AWS's own metadata — covers all present and future instance types.
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  effective_ami_id = var.os_image_ami_id != null ? var.os_image_ami_id : one(data.aws_ami.al2023[*].id)

  # VPC ID resolved from vpc_name, or null when vpc_name is not provided.
  named_vpc_id = try(data.aws_vpc.named[0].id, null)

  # Network handle: explicit subnet_id → named subnet → first default-VPC subnet. Never creates fabric.
  effective_subnet_id = coalesce(var.subnet_id, try(one(data.aws_subnet.by_name[*].id), null), try(sort(data.aws_subnets.default[0].ids)[0], null))

  # DNS is optional and name-only. cluster_fqdn is the API/kubeconfig name; wildcard covers it + services.
  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  # coalesce() errors if every argument is null (the common case: no DNS configured at
  # all), so a plain conditional is used instead — it tolerates both being null.
  effective_zone_id = var.hosted_zone_id != null ? var.hosted_zone_id : try(data.aws_route53_zone.private[0].zone_id, null)
  create_record     = local.has_domain && local.effective_zone_id != null

  # cluster_type drives the taint, never worker count: worker pools are separate state this
  # module cannot see, and node counts alone are ambiguous (double-duty HA vs dedicated CP).
  control_plane_taint = var.cluster_type == "dedicated_control_plane"

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-node"
  })
}

# ---- Join-token flow: pre-generated so a spine + pool join in one apply pass ----
# Two tokens, least privilege: the server token grants joining etcd/control-plane (used
# starting with the HA control-plane slice); the agent token is all a worker ever receives,
# so a compromised worker cannot rejoin as a control-plane/etcd member.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}

# Delivery is provider-shaped: on AWS, the agent token is mirrored into an SSM SecureString
# and fetched at boot via the instance's IAM role — it is never rendered into user_data.
resource "aws_ssm_parameter" "agent_token" {
  name  = "/kube-node/${var.cluster_name}/agent-token"
  type  = "SecureString"
  value = random_password.agent_token.result
  tags  = local.common_tags
}

# ---- Cluster security group: self-referencing, every cluster member (east-west) ----
# All-protocol among members rather than pinning to today's CNI ports: this SG is meant to
# outlive a CNI switch (flannel now, Cilium in a later slice) without a security-group edit.
resource "aws_security_group" "cluster" {
  name_prefix = "kube-node-${var.cluster_name}-cluster-"
  description = "kube-node ${var.cluster_name}: east-west traffic among cluster members only."
  vpc_id      = data.aws_subnet.selected.vpc_id
  tags        = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-cluster" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "all traffic among cluster members"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.cluster.id
  tags                         = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-cluster-self" })
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-cluster-egress-all" })
}

# ---- etcd security group: control-plane members only, never joined by workers ----
resource "aws_security_group" "control_plane_etcd" {
  name_prefix = "kube-node-${var.cluster_name}-etcd-"
  description = "kube-node ${var.cluster_name}: etcd peer/client traffic, control-plane nodes only."
  vpc_id      = data.aws_subnet.selected.vpc_id
  tags        = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-etcd" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "etcd_peer" {
  security_group_id            = aws_security_group.control_plane_etcd.id
  description                  = "etcd peer/client traffic among control-plane nodes"
  ip_protocol                  = "tcp"
  from_port                    = 2379
  to_port                      = 2380
  referenced_security_group_id = aws_security_group.control_plane_etcd.id
  tags                         = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-etcd-peer" })
}

resource "aws_vpc_security_group_egress_rule" "etcd_all" {
  security_group_id = aws_security_group.control_plane_etcd.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-etcd-egress-all" })
}

module "bootstrap" {
  source = "../node-bootstrap"

  cloud_init_template            = local.cloud_init_template
  cluster_name                   = var.cluster_name
  k8s_version                    = var.k8s_version
  cluster_fqdn                   = local.cluster_fqdn
  node_role                      = "server-init"
  control_plane_taint            = local.control_plane_taint
  cluster_token                  = random_password.server_token.result
  cluster_agent_token            = random_password.agent_token.result
  trusted_ca_pem                 = var.trusted_ca_pem
  registry_mirror_url            = var.registry_mirror_url
  gitops_platform_repo_url       = var.gitops_platform_repo_url
  gitops_platform_revision       = var.gitops_platform_revision
  gitops_workloads_repo_url      = var.gitops_workloads_repo_url
  gitops_workloads_revision      = var.gitops_workloads_revision
  gitops_workloads_path          = var.gitops_workloads_path
  cert_mode                      = var.cert_mode
  platform_extra_helm_parameters = var.platform_extra_helm_parameters
  platform_helm_values_object    = var.platform_helm_values_object
  extra_tags                     = var.extra_tags
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
  tags      = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-ingress-${each.value}" })
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
  tags              = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-ingress-${each.value.port}" })
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-egress-all" })
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

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "kube-node-${var.cluster_name}-"
  role        = aws_iam_role.node.name
  tags        = local.common_tags
}

# ---- The control-plane node ----
# Single resource this slice: control_plane_count > 1 is validated (accepted for the interface)
# but not yet provisioned — the precondition below fails plan explicitly rather than silently
# creating one node while three or five were requested.
resource "aws_instance" "control_plane" {
  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = local.effective_subnet_id
  vpc_security_group_ids = [aws_security_group.node.id, aws_security_group.cluster.id, aws_security_group.control_plane_etcd.id]
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

  # Marks every currently-attached EBS volume (root + any CSI-provisioned data
  # volumes) delete-on-termination right before the instance itself is
  # destroyed, so AWS deletes them as part of termination — no dependency on
  # the cluster's API server, kubectl, or SSM being reachable at destroy time.
  #
  # Destroy-time provisioners may only reference `self` (OpenTofu/Terraform
  # rejects var./resource references here to avoid destroy-order cycles) —
  # region is derived from self.availability_zone since var.aws_region isn't
  # allowed.
  provisioner "local-exec" {
    when       = destroy
    on_failure = continue
    command    = <<-EOT
      REGION="${substr(self.availability_zone, 0, length(self.availability_zone) - 1)}"
      MAPPINGS=$(aws ec2 describe-volumes --region "$REGION" \
        --filters Name=attachment.instance-id,Values=${self.id} \
        --query 'Volumes[].Attachments[0].{DeviceName:Device,Ebs:{DeleteOnTermination:`true`}}' \
        --output json)
      if [ -n "$MAPPINGS" ] && [ "$MAPPINGS" != "[]" ]; then
        aws ec2 modify-instance-attribute --region "$REGION" \
          --instance-id ${self.id} --block-device-mappings "$MAPPINGS"
      fi
    EOT
  }

  lifecycle {
    # Don't replace on AL2023 AMI patch drift; remove to deliberately upgrade.
    ignore_changes = [ami]

    precondition {
      condition     = var.control_plane_count == 1
      error_message = "control_plane_count > 1 is not yet provisioned by spine-aws (multi-AZ control-plane fan-out and the registration load balancer land in a later slice); only 1 is supported today."
    }
  }
}

# ---- Optional DNS convenience: wildcard A record in a Route53 zone you already own ----
# Created ONLY when cluster_domain is set and a zone is resolvable (hosted_zone_name or hosted_zone_id). Otherwise the module owns no DNS;
# register *.${cluster}.${domain} -> cluster_ip in your DNS of choice using the wildcard_dns_name output.
resource "aws_route53_record" "wildcard" {
  count   = local.create_record ? 1 : 0
  zone_id = local.effective_zone_id
  name    = local.wildcard_name
  type    = "A"
  ttl     = 60
  records = [aws_instance.control_plane.private_ip]
}
