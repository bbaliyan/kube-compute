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

  # The map's own keys ARE the distinct AZs — no data source needed to discover them.
  distinct_control_plane_azs = var.control_plane_subnets != null ? sort(keys(var.control_plane_subnets)) : []

  # One subnet id per control-plane node, cycling through the distinct AZs (round-robins if
  # control_plane_count exceeds the number of distinct AZs available, e.g. 5 nodes in a 3-AZ
  # region — the >= 3 AZ requirement below is still enforced regardless).
  control_plane_subnet_ids = var.control_plane_count > 1 && length(local.distinct_control_plane_azs) > 0 ? [
    for i in range(var.control_plane_count) :
    var.control_plane_subnets[local.distinct_control_plane_azs[i % length(local.distinct_control_plane_azs)]]
  ] : []

  # Genesis keeps using the existing single-subnet resolution for control_plane_count = 1
  # (byte-for-byte the same behavior as before this task); for HA it takes the first AZ slot.
  # try() guards against an empty control_plane_subnet_ids list (e.g. control_plane_subnets = {}
  # or zero AZs resolved) so evaluation fails via the precondition below with a clear message,
  # not a raw index-out-of-range crash.
  genesis_subnet_id = var.control_plane_count > 1 ? try(local.control_plane_subnet_ids[0], local.effective_subnet_id) : local.effective_subnet_id

  # In HA mode, the module's VPC is derived from the control-plane subnets themselves — the
  # single-node subnet_id/subnet_name fallback is otherwise unused once control_plane_count > 1,
  # and deriving VPC from it independently risked creating security groups/the NLB target group
  # in a different VPC than where the instances actually launch.
  module_vpc_id = var.control_plane_count > 1 ? data.aws_subnet.control_plane_genesis[0].vpc_id : data.aws_subnet.selected.vpc_id

  # Null for control_plane_count = 1 (no registration endpoint — ADR 0003); the NLB's DNS name
  # once there's more than one control-plane node.
  registration_address = var.control_plane_count > 1 ? try(aws_lb.control_plane[0].dns_name, null) : null

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
  vpc_id      = local.module_vpc_id
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
  vpc_id      = local.module_vpc_id
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
  registration_address           = local.registration_address
  extra_tls_sans                 = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
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

# ---- Additional control-plane nodes (2..N): server-join, one per remaining AZ ----
# Explicitly depends_on the genesis node (ADR 0007's first-server ordering) — server-join
# retries against the registration endpoint, so no ordering among the additional nodes
# themselves is needed, only "after the genesis node exists."
module "bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../node-bootstrap"

  cloud_init_template  = local.cloud_init_template
  cluster_name         = var.cluster_name
  k8s_version          = var.k8s_version
  cluster_fqdn         = local.cluster_fqdn
  node_role            = "server-join"
  control_plane_taint  = local.control_plane_taint
  registration_address = local.registration_address
  extra_tls_sans       = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  cluster_token        = random_password.server_token.result
  trusted_ca_pem       = var.trusted_ca_pem
  registry_mirror_url  = var.registry_mirror_url
  cert_mode            = var.cert_mode
  extra_tags           = var.extra_tags
  # gitops_* intentionally omitted (defaults to null): Argo/platform bootstrap runs on the
  # first server only (ADR 0007) — node-bootstrap also enforces this at the render level.
}

resource "aws_instance" "control_plane_additional" {
  for_each = var.control_plane_count > 1 && length(local.control_plane_subnet_ids) > 0 ? { for i in range(1, var.control_plane_count) : tostring(i) => local.control_plane_subnet_ids[i] } : {}

  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = each.value
  vpc_security_group_ids = [aws_security_group.node.id, aws_security_group.cluster.id, aws_security_group.control_plane_etcd.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-cp-${tonumber(each.key) + 1}-root" })
  }

  user_data_base64            = module.bootstrap_additional[each.key].user_data_base64
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-cp-${tonumber(each.key) + 1}" })

  depends_on = [aws_instance.control_plane]

  lifecycle {
    ignore_changes = [ami]
  }
}

# ---- Internal NLB fronting the control plane on 6443 (control_plane_count > 1 only) ----
# ADR 0003: no registration endpoint at all for control_plane_count = 1; an internal NLB is the
# default HA mode on cloud (a floating VIP cannot cross AWS AZ boundaries). dns/static endpoint
# modes are a later option (issue 015), not implemented here.
resource "aws_lb" "control_plane" {
  count              = var.control_plane_count > 1 ? 1 : 0
  name_prefix        = "cp-lb-"
  internal           = true
  load_balancer_type = "network"
  subnets            = distinct(local.control_plane_subnet_ids)
  tags               = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-cp" })
}

resource "aws_lb_target_group" "control_plane" {
  count       = var.control_plane_count > 1 ? 1 : 0
  name_prefix = "cp-tg-"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = local.module_vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "6443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = merge(local.common_tags, { Name = "kube-node-${var.cluster_name}-cp" })
}

resource "aws_lb_listener" "control_plane" {
  count             = var.control_plane_count > 1 ? 1 : 0
  load_balancer_arn = aws_lb.control_plane[0].arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.control_plane[0].arn
  }
}

resource "aws_lb_target_group_attachment" "genesis" {
  count            = var.control_plane_count > 1 ? 1 : 0
  target_group_arn = aws_lb_target_group.control_plane[0].arn
  target_id        = aws_instance.control_plane.id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "additional" {
  for_each         = aws_instance.control_plane_additional
  target_group_arn = aws_lb_target_group.control_plane[0].arn
  target_id        = each.value.id
  port             = 6443
}

# ---- Module-owned security group (NOT fabric) ----
resource "aws_security_group" "node" {
  name_prefix = "kube-node-${var.cluster_name}-"
  description = "kube-node ${var.cluster_name}: cluster access ports only, no SSH."
  vpc_id      = local.module_vpc_id
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

# ---- The control-plane node (genesis: server-init) ----
# control_plane_count additional nodes (server-join) are provisioned below in
# aws_instance.control_plane_additional. The precondition here fails plan explicitly when
# control_plane_count > 1 but fewer than 3 distinct AZs were resolved from control_plane_subnets,
# rather than silently under-spreading the quorum.
resource "aws_instance" "control_plane" {
  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = local.genesis_subnet_id
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
      condition     = var.control_plane_count == 1 || length(local.distinct_control_plane_azs) >= 3
      error_message = "control_plane_count > 1 requires at least 3 distinct availability zones among the resolved control-plane subnets (got ${length(local.distinct_control_plane_azs)}); pass control_plane_subnets spanning >= 3 AZs."
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
