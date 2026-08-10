# SPDX-License-Identifier: Apache-2.0
locals {
  # AWS's own docs list AlmaLinux among AMIs that "likely" ship the SSM
  # Agent pre-installed (Community/Marketplace AMIs, not AWS-guaranteed, can
  # be present-but-not-running) — so this defensively enables/starts it
  # rather than installing it; `|| true` tolerates the rare case it's
  # genuinely absent. Kept independent of RKE2/node-bootstrap: SSM is this
  # module's ongoing operator-access path (break-glass shell, verb-scripts —
  # see node_control_ref below), not merely a bootstrap-time transport, so it
  # stays enabled even though nothing runs live Ansible over it anymore.
  connectivity_user_data = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  # AWS accepts only one user_data string per instance. Cloud-init's own
  # MIME multipart/mixed convention combines this AWS-only SSM-agent-enable
  # script with node-bootstrap's #cloud-config payload without this module
  # needing to know node-bootstrap's internal cloud-config shape (decoding
  # and re-merging the YAML would create exactly that coupling). Every
  # control-plane node — genesis and each additional server — gets its own
  # combined document, keyed the same way the per-node module calls below
  # already are ("0" for genesis, node_bootstrap_additional's own keys for
  # the rest).
  mime_boundary = "MIMEBOUNDARY"

  cloud_init_payloads = merge(
    { "0" = module.node_bootstrap.cloud_init_user_data },
    { for k, m in module.node_bootstrap_additional : k => m.cloud_init_user_data }
  )

  combined_user_data = {
    for k, payload in local.cloud_init_payloads : k => join("\n", [
      "Content-Type: multipart/mixed; boundary=\"${local.mime_boundary}\"",
      "MIME-Version: 1.0",
      "",
      "--${local.mime_boundary}",
      "Content-Type: text/x-shellscript; charset=\"us-ascii\"",
      "",
      local.connectivity_user_data,
      "--${local.mime_boundary}",
      "Content-Type: text/cloud-config; charset=\"us-ascii\"",
      "",
      payload,
      "--${local.mime_boundary}--",
      "",
    ])
  }

  # Arch from AWS's own metadata — covers all present and future instance types.
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  effective_ami_id = var.os_image_ami_id != null ? var.os_image_ami_id : one(data.aws_ami.almalinux10[*].id)

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

  # cluster_type drives the taint, never worker count: node pools are separate state this
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

  # Null for control_plane_count = 1 (no registration endpoint). For control_plane_count
  # > 1, the shape depends on endpoint_mode: the NLB's DNS name (loadbalancer, the default), the
  # shared Route53 record name (dns), or the consumer-supplied address verbatim (static).
  registration_address = var.control_plane_count == 1 ? null : (
    var.endpoint_mode == "static" ? var.static_registration_address :
    var.endpoint_mode == "dns" ? local.dns_registration_name :
    try(aws_lb.control_plane[0].dns_name, null)
  )

  # Cilium is the standard CNI regardless of topology (Canal/flannel's iptables/ipset
  # dataplane is broken on AlmaLinux 10, this project's only supported OS — see
  # node-bootstrap's cni variable). null means "use the default".
  effective_cni = coalesce(var.cni, "cilium")

  # dns mode's shared record name — distinct from cluster_fqdn (api.<...>), which is the
  # kubeconfig/API-cert name; this is the join-time registration name. Null unless a domain is
  # configured, enforced by the precondition on aws_instance.control_plane below.
  dns_registration_name = local.has_domain ? "cp.${local.fqdn_suffix}" : null

  # All control-plane instances, keyed by the same "cp-N" suffix used in control_plane_node_refs,
  # for per-node DNS/health-check/alarm resources.
  control_plane_instances = merge(
    { "1" = aws_instance.control_plane },
    { for i, inst in aws_instance.control_plane_additional : tostring(tonumber(i) + 1) => inst }
  )

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })
}

# ---- etcd security group: control-plane members only, never joined by workers ----
resource "aws_security_group" "control_plane_etcd" {
  name_prefix = "kube-compute-${var.cluster_name}-etcd-"
  description = "kube-compute ${var.cluster_name}: etcd peer/client traffic, control-plane nodes only."
  vpc_id      = local.module_vpc_id
  tags        = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-etcd" })

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
  tags                         = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-etcd-peer" })
}

resource "aws_vpc_security_group_egress_rule" "etcd_all" {
  security_group_id = aws_security_group.control_plane_etcd.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-etcd-egress-all" })
}

module "node_bootstrap" {
  source = "../node-bootstrap"

  cluster_name                   = var.cluster_name
  node_name                      = "${var.cluster_name}-cp-1"
  cluster_fqdn                   = local.cluster_fqdn
  cluster_fqdn_suffix            = local.fqdn_suffix
  node_role                      = "server-init"
  control_plane_taint            = local.control_plane_taint
  cni                            = local.effective_cni
  cluster_token                  = var.cluster_token
  cluster_agent_token            = var.cluster_agent_token
  registration_address           = local.registration_address
  extra_tls_sans                 = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  trusted_ca_pem                 = var.trusted_ca_pem
  registry_mirror_url            = var.registry_mirror_url
  gitops_platform_enabled        = var.gitops_platform_enabled
  gitops_platform_repo_url       = var.gitops_platform_repo_url_override
  gitops_platform_revision       = var.gitops_platform_revision_override
  gitops_workloads_repo_url      = var.gitops_workloads_repo_url
  gitops_workloads_revision      = var.gitops_workloads_revision
  gitops_workloads_path          = var.gitops_workloads_path
  cert_mode                      = var.cert_mode
  platform_extra_helm_parameters = var.platform_extra_helm_parameters
  platform_helm_values_object    = var.platform_helm_values_object
  extra_tags                     = var.extra_tags
}

# ---- Additional control-plane nodes (2..N): server-join, one per remaining AZ ----
# node-bootstrap renders a plan-time-only cloud-init payload now (no live connection,
# no run to wait for), so there is no ordering concern here beyond what RKE2's own
# join retry already absorbs: a sibling starting concurrently with genesis just waits
# out genesis's install via its own connection retry, the same way a worker retries
# its join target. Ordering *among* the additional nodes themselves (the real
# constraint — one non-voting etcd learner at a time) is handled by node-bootstrap's
# own staggered, self-healing join-race retry inside bootstrap.sh.
module "node_bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../node-bootstrap"

  cluster_name         = var.cluster_name
  node_name            = "${var.cluster_name}-cp-${tonumber(each.key) + 1}"
  cluster_fqdn         = local.cluster_fqdn
  cluster_fqdn_suffix  = local.fqdn_suffix
  node_role            = "server-join"
  control_plane_taint  = local.control_plane_taint
  cni                  = local.effective_cni
  registration_address = local.registration_address
  extra_tls_sans       = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  cluster_token        = var.cluster_token
  trusted_ca_pem       = var.trusted_ca_pem
  registry_mirror_url  = var.registry_mirror_url
  cert_mode            = var.cert_mode
  extra_tags           = var.extra_tags
  # gitops_* intentionally omitted (defaults to null): Argo/platform bootstrap runs on the
  # first server only — node-bootstrap also enforces this at the task level.
}

resource "aws_instance" "control_plane_additional" {
  for_each = var.control_plane_count > 1 && length(local.control_plane_subnet_ids) > 0 ? { for i in range(1, var.control_plane_count) : tostring(i) => local.control_plane_subnet_ids[i] } : {}

  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = each.value
  vpc_security_group_ids = [aws_security_group.node.id, var.cluster_security_group_id, aws_security_group.control_plane_etcd.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # hop_limit 3, not AWS's generally-documented 2: confirmed live that 2 isn't
  # enough for a pod (not just the host) to complete an IMDSv2 token PUT
  # through Cilium — see the genesis instance's metadata_options below for the
  # full story.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
  }

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp-${tonumber(each.key) + 1}-root" })
  }

  user_data_base64            = base64gzip(local.combined_user_data[each.key])
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp-${tonumber(each.key) + 1}" })

  depends_on = [aws_instance.control_plane]

  lifecycle {
    ignore_changes = [ami]
  }
}

# ---- Internal NLB fronting the control plane on 6443 (control_plane_count > 1, endpoint_mode = "loadbalancer" only) ----
# No registration endpoint at all for control_plane_count = 1; an internal NLB is the
# default HA mode on cloud (a floating VIP cannot cross AWS AZ boundaries). See endpoint_mode for
# the dns/static alternatives, gated below.
resource "aws_lb" "control_plane" {
  count              = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
  name_prefix        = "cp-lb-"
  internal           = true
  load_balancer_type = "network"
  subnets            = distinct(local.control_plane_subnet_ids)
  tags               = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp" })
}

resource "aws_lb_target_group" "control_plane" {
  count       = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
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

  tags = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp" })
}

resource "aws_lb_listener" "control_plane" {
  count             = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
  load_balancer_arn = aws_lb.control_plane[0].arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.control_plane[0].arn
  }
}

resource "aws_lb_target_group_attachment" "genesis" {
  count            = var.control_plane_count > 1 && var.endpoint_mode == "loadbalancer" ? 1 : 0
  target_group_arn = aws_lb_target_group.control_plane[0].arn
  target_id        = aws_instance.control_plane.id
  port             = 6443
}

resource "aws_lb_target_group_attachment" "additional" {
  for_each         = var.endpoint_mode == "loadbalancer" ? aws_instance.control_plane_additional : {}
  target_group_arn = aws_lb_target_group.control_plane[0].arn
  target_id        = each.value.id
  port             = 6443
}

# ---- dns endpoint mode: Route53 multivalue-answer records, one per control-plane node ----
# Route53's public health-checker fleet cannot reach a private VPC IP directly, so each record's
# health check is CLOUDWATCH_METRIC-type, backed by that instance's own EC2 status-check alarm —
# the standard bridge for private-IP Route53 failover.
resource "aws_cloudwatch_metric_alarm" "control_plane_health" {
  for_each = var.control_plane_count > 1 && var.endpoint_mode == "dns" ? local.control_plane_instances : {}

  alarm_name          = "kube-compute-${var.cluster_name}-cp-${each.key}-status-check"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  dimensions = {
    InstanceId = each.value.id
  }
  tags = local.common_tags
}

resource "aws_route53_health_check" "control_plane" {
  for_each = var.control_plane_count > 1 && var.endpoint_mode == "dns" ? local.control_plane_instances : {}

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.control_plane_health[each.key].alarm_name
  cloudwatch_alarm_region         = var.aws_region
  insufficient_data_health_status = "Unhealthy"
  tags                            = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp-${each.key}" })
}

resource "aws_route53_record" "control_plane_dns" {
  for_each = var.control_plane_count > 1 && var.endpoint_mode == "dns" ? local.control_plane_instances : {}

  zone_id                          = local.effective_zone_id
  name                             = local.dns_registration_name
  type                             = "A"
  ttl                              = 10
  records                          = [each.value.private_ip]
  set_identifier                   = "cp-${each.key}"
  health_check_id                  = aws_route53_health_check.control_plane[each.key].id
  multivalue_answer_routing_policy = true
}

# ---- Module-owned security group (NOT fabric) ----
resource "aws_security_group" "node" {
  name_prefix = "kube-compute-${var.cluster_name}-"
  description = "kube-compute ${var.cluster_name}: cluster access ports only, no SSH."
  vpc_id      = local.module_vpc_id
  tags        = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}" })

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
  tags      = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-ingress-${each.value}" })
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
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-ingress-${each.value.port}" })
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-egress-all" })
}

# ---- IAM: SSM-managed instance for the control-plane (send-command/session) ----
# Inline JSON avoids a data.aws_iam_policy_document block that mock_provider cannot evaluate.
resource "aws_iam_role" "node" {
  name_prefix = "kube-compute-${var.cluster_name}-"
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
  name_prefix = "kube-compute-${var.cluster_name}-"
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
  vpc_security_group_ids = [aws_security_group.node.id, var.cluster_security_group_id, aws_security_group.control_plane_etcd.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # hop_limit 3, not the commonly-documented 2 (AWS's own docs say 2 is enough
  # for "containerized applications" generally). Confirmed live on this
  # cluster: with hop_limit 2, a pod's IMDSv2 token PUT completes its TCP
  # handshake fine (proving basic pod<->host routing works — this isn't a
  # masquerade/connectivity problem) but the token response itself never
  # arrives ("Operation timed out ... 0 bytes received"). IMDSv2 deliberately
  # caps that response's IP TTL to the configured hop_limit as an anti-SSRF
  # control, and it's getting dropped as TTL-exceeded one hop short — Cilium's
  # own veth + internal routing between a pod's netns and the host evidently
  # costs 2 hops here, not the 1 hop AWS's generic guidance assumes for
  # "a container". Mutable in place (not ForceNew on aws_instance) — no
  # replacement needed to pick this up.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
  }

  root_block_device {
    volume_type           = var.root_volume_type
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-root" })
  }

  user_data_base64            = base64gzip(local.combined_user_data["0"])
  user_data_replace_on_change = true # disposable nodes: replace on bootstrap change

  tags = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}" })

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
    # Don't replace on AlmaLinux 10 AMI patch drift; remove to deliberately upgrade.
    ignore_changes = [ami]

    precondition {
      condition     = var.control_plane_count == 1 || length(local.distinct_control_plane_azs) >= 3
      error_message = "control_plane_count > 1 requires at least 3 distinct availability zones among the resolved control-plane subnets (got ${length(local.distinct_control_plane_azs)}); pass control_plane_subnets spanning >= 3 AZs."
    }

    precondition {
      condition     = var.endpoint_mode != "dns" || (local.has_domain && local.effective_zone_id != null)
      error_message = "endpoint_mode = \"dns\" requires cluster_domain to be set and a resolvable hosted zone (hosted_zone_id or hosted_zone_name)."
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
