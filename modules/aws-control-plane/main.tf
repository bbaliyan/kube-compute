# SPDX-License-Identifier: Apache-2.0
# Tokens owned here directly, matching proxmox-control-plane's precedent. Two tokens for
# least privilege: server token joins etcd/control-plane; agent token is all a worker gets,
# so a compromised worker can't rejoin as control-plane/etcd.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}

locals {
  # AlmaLinux community AMIs "likely" ship SSM Agent pre-installed but not guaranteed
  # running, so this enables/starts it defensively (`|| true` covers the rare absent
  # case). Independent of RKE2/node-bootstrap: SSM is this module's ongoing
  # operator-access path (break-glass shell, verb-scripts — see node_control_ref below),
  # not just a bootstrap-time transport.
  connectivity_user_data = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  # AWS accepts only one user_data string per instance. MIME multipart/mixed combines the
  # SSM-enable script with node-bootstrap's #cloud-config payload without decoding/re-merging
  # the YAML (which would couple this module to node-bootstrap's internal shape). Keyed like
  # the module calls below: "0" for genesis, node_bootstrap_additional's keys for the rest.
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

  # ---- user data: payload, or pointer to it --------------------------------------
  #
  # EC2 rejects RunInstances when decoded user data exceeds 16384 bytes. This module
  # reached that on a real cluster: a control plane carrying the platform Argo CD
  # Application, a CAPI bundle with one bootstrap Secret per worker group, and a
  # corporate CA came to 16635 bytes and could not be created. Compression was
  # already in play (user_data_base64 = base64gzip below) and there was nothing left
  # to squeeze.
  #
  # So above a budget the payload stops travelling in user data. It goes into SSM
  # parameters and user data becomes a stub that fetches and runs it -- what AWS's
  # own documentation recommends for this limit, and what Cluster API's AWS provider
  # does for the same reason (AWSMachine.spec.cloudInit.secureSecretsBackend).
  #
  # An input rather than something this module measures for itself. The payload
  # carries a freshly generated join token, so its size is unknown until apply, and
  # a delivery mode discovered at apply time cannot drive the parameters and the IAM
  # policy the mode needs. Cluster API's AWS provider makes the same call for the
  # same reason (secureSecretsBackend is configuration, not a heuristic). The
  # precondition on the instance below turns the AWS-side rejection into a message
  # that names this variable, so nobody has to know the number.
  payload_in_ssm = var.bootstrap_payload_in_ssm

  # What RunInstances measures: the decoded size of user_data_base64. Known only at
  # apply, which is where the precondition using it runs.
  inline_user_data_bytes = {
    for k, v in local.combined_user_data : k => floor(length(base64gzip(v)) / 4) * 3
  }

  # The script form of the same payload. A fetched cloud-config would have nothing
  # to process it; a fetched script runs.
  node_setup_scripts = local.payload_in_ssm ? {
    for k, m in merge({ "0" = module.node_bootstrap }, module.node_bootstrap_additional) :
    k => m.node_setup_script
  } : {}

  # 4000 bytes per piece: an SSM Standard parameter's value caps at 4096 and costs
  # nothing, where Advanced tier holds 8192 and is billed per parameter per month.
  # A multiple of 4, so every piece stays base64-aligned.
  payload_chunk_bytes = 4000

  # A FIXED number of pieces, not one per 4000 bytes of payload. The payload's length
  # is not knowable at plan -- it carries a generated join token and the ids of
  # resources this same plan creates -- and a resource's for_each cannot depend on an
  # unknown. So the count is configuration and the payload is padded to fill it.
  #
  # Padded with newlines, which base64 ignores: the node concatenates the pieces and
  # decodes, and the padding disappears. That also makes every piece exactly
  # payload_chunk_bytes, so the plan reads the same whatever the payload does.
  #
  # 12 pieces is 48000 base64 characters, about 36 KB of compressed payload, against
  # the ~33 KB a real multi-group cluster renders today. Raise it if the precondition
  # below ever fires; each piece is free, and the only cost of spare ones is a line
  # in the plan.
  payload_piece_count = 12
  payload_total_bytes = local.payload_piece_count * local.payload_chunk_bytes

  node_payload_encoded = { for k, v in local.node_setup_scripts : k => base64gzip(v) }

  # A constant, so it is known at plan even where the payload is not. Built in two
  # steps because range() refuses to generate more than 1024 values, and of newlines
  # specifically because a newline is the one non-alphabet character base64 decoding
  # is guaranteed to skip -- spaces would make it fail.
  payload_padding_unit = join("", [for _ in range(1000) : "\n"])
  payload_padding      = join("", [for _ in range(ceil(local.payload_total_bytes / 1000)) : local.payload_padding_unit])

  node_payload_padded = {
    for k, enc in local.node_payload_encoded :
    k => substr("${enc}${local.payload_padding}", 0, local.payload_total_bytes)
  }

  node_payload_piece_keys = toset(flatten([
    for k, _ in local.node_setup_scripts : [
      for i in range(local.payload_piece_count) : "${k}/${i + 1}"
    ]
  ]))

  node_payload_pieces = {
    for key in local.node_payload_piece_keys : key => substr(
      local.node_payload_padded[split("/", key)[0]],
      (tonumber(split("/", key)[1]) - 1) * local.payload_chunk_bytes,
      local.payload_chunk_bytes,
    )
  }

  user_data_stub = {
    for k, enc in local.node_payload_encoded : k => templatefile("${path.module}/templates/user-data-stub.sh.tftpl", {
      cluster_name = var.cluster_name
      aws_region   = var.aws_region
      payload_sha  = sha256(enc)
      parameter_names = [
        for i in range(local.payload_piece_count) :
        aws_ssm_parameter.node_payload["${k}/${i + 1}"].name
      ]
    })
  }

  effective_user_data = {
    for k, v in local.combined_user_data :
    k => local.payload_in_ssm ? local.user_data_stub[k] : v
  }

  # Arch from AWS's own metadata — covers all present and future instance types.
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  effective_ami_id = coalesce(
    var.os_image_ami_id,
    try(one(data.aws_ami.by_name[*].id), null),
    try(one(data.aws_ami.almalinux10[*].id), null),
  )

  # VPC ID resolved from vpc_name, or null when vpc_name is not provided.
  named_vpc_id = try(data.aws_vpc.named[0].id, null)

  # subnet_name is the one-element case of subnet_names; both variables funnel into this list so the
  # lookup and selection below have a single shape to deal with.
  subnet_name_candidates = var.subnet_names != null ? var.subnet_names : (var.subnet_name != null ? [var.subnet_name] : [])

  # Whether the caller pinned placement at all. When they did not, the default-VPC fallback applies.
  has_explicit_subnet = var.subnet_id != null || length(local.subnet_name_candidates) > 0

  # First candidate, in the caller's order, that still has a free IP. Preserving their order rather
  # than picking the emptiest subnet is what keeps placement stable: a node only moves when the
  # subnet it sits in is genuinely full, and moving it REPLACES the instance.
  named_subnet_id = try([
    for name in local.subnet_name_candidates :
    data.aws_subnet.by_name[name].id
    if data.aws_subnet.by_name[name].available_ip_address_count > 0
  ][0], null)

  # Network handle: explicit subnet_id → named subnet → first default-VPC subnet. Never creates fabric.
  # Wrapped in try so that resolving to nothing stays null: coalesce raises on all-null arguments,
  # and its "no non-null arguments" error would surface instead of the preconditions below, which
  # can actually say which of the two ways to end up with no subnet happened.
  effective_subnet_id = try(coalesce(var.subnet_id, local.named_subnet_id, try(sort(data.aws_subnets.default[0].ids)[0], null)), null)

  # DNS is optional and name-only. cluster_fqdn is the API/kubeconfig name; wildcard covers it + services.
  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null
  # coalesce() errors if every argument is null (the common case: no DNS configured at
  # all), so a plain conditional is used instead — it tolerates both being null.
  effective_zone_id = var.hosted_zone_id != null ? var.hosted_zone_id : try(data.aws_route53_zone.private[0].zone_id, null)
  create_record     = local.has_domain && local.effective_zone_id != null

  # An IAM name_prefix caps at 38 characters, where a security group's does not,
  # and cluster_name allows up to 31 -- so a legal name could fail at apply after
  # the rest of the plan had already been created. substr returns the whole string
  # when it is shorter than the limit, so this changes no existing role's prefix.
  node_iam_name_prefix = format("kube-compute-%s-", substr(var.cluster_name, 0, 24))

  # Split from create_record so external-dns can own the wildcard without
  # costing the cluster its api. record, which is what agents join through.
  create_wildcard_record = local.create_record && var.manage_wildcard_dns_record

  # cluster_type drives the taint, never worker count: node pools are separate state this
  # module cannot see, and node counts alone are ambiguous (double-duty HA vs dedicated CP).
  control_plane_taint = var.cluster_type == "dedicated_control_plane"

  # The map's own keys ARE the distinct AZs — no data source needed to discover them.
  distinct_control_plane_azs = var.control_plane_subnets != null ? sort(keys(var.control_plane_subnets)) : []

  # One subnet per control-plane node, round-robin across distinct AZs (e.g. 5 nodes in a
  # 3-AZ region); the >= 3 AZ requirement below is still enforced.
  control_plane_subnet_ids = var.control_plane_count > 1 && length(local.distinct_control_plane_azs) > 0 ? [
    for i in range(var.control_plane_count) :
    var.control_plane_subnets[local.distinct_control_plane_azs[i % length(local.distinct_control_plane_azs)]]
  ] : []

  # control_plane_count = 1 keeps the single-subnet resolution unchanged; HA takes the first
  # AZ slot. try() guards an empty control_plane_subnet_ids list so evaluation fails via the
  # precondition below with a clear message, not a raw index-out-of-range crash.
  genesis_subnet_id = var.control_plane_count > 1 ? try(local.control_plane_subnet_ids[0], local.effective_subnet_id) : local.effective_subnet_id

  # HA mode derives VPC from the control-plane subnets themselves, not the single-node
  # fallback (unused once control_plane_count > 1) — avoids creating SGs/the NLB target
  # group in a different VPC than where instances actually launch.
  module_vpc_id = var.control_plane_count > 1 ? data.aws_subnet.control_plane_genesis[0].vpc_id : data.aws_subnet.selected.vpc_id

  # Null when control_plane_count = 1. Otherwise depends on endpoint_mode: NLB DNS name
  # (loadbalancer, default), shared Route53 record (dns), or static_registration_address (static).
  registration_address = var.control_plane_count == 1 ? null : (
    var.endpoint_mode == "static" ? var.static_registration_address :
    var.endpoint_mode == "dns" ? local.dns_registration_name :
    try(aws_lb.control_plane[0].dns_name, null)
  )

  # Cilium is standard regardless of topology — Canal/flannel's iptables/ipset dataplane is
  # broken on AlmaLinux 10 (this project's only supported OS; see node-bootstrap's cni
  # variable). null = default.
  effective_cni = coalesce(var.cni, "cilium")

  # dns mode's shared record name, distinct from cluster_fqdn (the kubeconfig/API-cert
  # name). Null unless a domain is configured; enforced by the precondition on
  # aws_instance.control_plane below.
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

# ---- Delivery: the agent token is mirrored into an SSM SecureString and fetched at
# boot via the worker's own instance IAM role — never rendered into user_data.
resource "aws_ssm_parameter" "agent_token" {
  name  = "/kube-compute/${var.cluster_name}/agent-token"
  type  = "SecureString"
  value = random_password.agent_token.result
  tags  = local.common_tags
}

# One node's boot payload, in free Standard-tier pieces, for the nodes whose payload
# does not fit in user data. SecureString because this is a node's whole bootstrap
# configuration: join tokens, the trusted CA, whatever registries.yaml carries.
#
# These outlive the boot they are named for on purpose. The node reads them again on
# every rebuild, which is exactly when a cluster is least able to spare a missing
# input, so deleting them after bootstrap would trade a free parameter for a cluster
# that cannot be rebuilt from code.
resource "aws_ssm_parameter" "node_payload" {
  for_each = local.node_payload_piece_keys

  name  = "/kube-compute/${var.cluster_name}/node-payload/${each.key}"
  type  = "SecureString"
  tier  = "Standard"
  value = local.node_payload_pieces[each.key]
  tags = merge(local.common_tags, {
    Name = "kube-compute-${var.cluster_name}-payload-${replace(each.key, "/", "-")}"
  })

  lifecycle {
    precondition {
      # The payload has to fit the pieces reserved for it. Checked at apply, because
      # that is the first moment its length is known, and long before the node that
      # would otherwise fail to decode it.
      condition     = nonsensitive(length(local.node_payload_encoded[split("/", each.key)[0]])) <= local.payload_total_bytes
      error_message = "This node's boot payload does not fit the ${local.payload_piece_count} pieces reserved for it (${local.payload_total_bytes} base64 characters). Raise payload_piece_count in aws-control-plane; the pieces are free."
    }
  }
}

# Read access for the instance that boots from it, scoped to this cluster's payload
# prefix. Created only when something is actually stored there.
resource "aws_iam_role_policy" "node_payload_read" {
  count = local.payload_in_ssm ? 1 : 0
  name  = "node-payload-read"
  role  = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/kube-compute/${var.cluster_name}/node-payload/*"
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" }
        }
      },
    ]
  })
}

# All-protocol among members (not pinned to today's CNI ports) so it outlives a CNI
# switch. Owned here rather than a separate module since aws-node-pool attaches to it
# by real ID (vpc_security_group_ids) — a hard AWS API dependency, unlike Proxmox's
# name-based ipsets.
resource "aws_security_group" "cluster" {
  name_prefix = "kube-compute-${var.cluster_name}-cluster-"
  description = "kube-compute ${var.cluster_name}: east-west traffic among cluster members only."
  vpc_id      = local.module_vpc_id
  tags        = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster_self" {
  security_group_id            = aws_security_group.cluster.id
  description                  = "all traffic among cluster members"
  ip_protocol                  = "-1"
  referenced_security_group_id = aws_security_group.cluster.id
  tags                         = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster-self" })
}

resource "aws_vpc_security_group_egress_rule" "cluster_all" {
  security_group_id = aws_security_group.cluster.id
  description       = "all egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  tags              = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cluster-egress-all" })
}

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

  cluster_name                    = var.cluster_name
  node_name                       = "${var.cluster_name}-cp-1"
  node_fqdn_label                 = "cp-1"
  cluster_fqdn                    = local.cluster_fqdn
  cluster_fqdn_suffix             = local.fqdn_suffix
  node_role                       = "server-init"
  control_plane_taint             = local.control_plane_taint
  cni                             = local.effective_cni
  cluster_token                   = random_password.server_token.result
  cluster_agent_token             = random_password.agent_token.result
  registration_address            = local.registration_address
  extra_tls_sans                  = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  trusted_ca_pem                  = var.trusted_ca_pem
  registry_mirror_url             = var.registry_mirror_url
  dns_servers                     = var.dns_servers
  gitops_platform_enabled         = var.gitops_platform_enabled
  gitops_platform_repo_url        = var.gitops_platform_repo_url_override
  gitops_platform_revision        = var.gitops_platform_revision_override
  gitops_workloads_repo_url       = var.gitops_workloads_repo_url
  gitops_workloads_revision       = var.gitops_workloads_revision
  gitops_workloads_path           = var.gitops_workloads_path
  workloads_extra_helm_parameters = var.workloads_extra_helm_parameters
  workloads_helm_values_object    = var.workloads_helm_values_object
  cert_mode                       = var.cert_mode
  platform_extra_helm_parameters  = var.platform_extra_helm_parameters
  platform_helm_values_object     = var.platform_helm_values_object
  extra_tags                      = var.extra_tags

  genesis_apply_manifests               = var.genesis_apply_manifests
  cluster_autoscaler_crd_wait_enabled   = var.cluster_autoscaler_crd_wait_enabled
  cluster_autoscaler_capi_install_baked = var.cluster_autoscaler_capi_install_baked
}

# node-bootstrap renders a plan-time-only cloud-init payload (no live connection to wait
# on), so ordering relies on RKE2's own join retry: a sibling starting alongside genesis
# just retries its connection until genesis is ready. Ordering among the additional nodes
# themselves (one non-voting etcd learner at a time) is handled by node-bootstrap's own
# staggered join-race retry inside bootstrap.sh.
module "node_bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../node-bootstrap"

  cluster_name         = var.cluster_name
  node_name            = "${var.cluster_name}-cp-${tonumber(each.key) + 1}"
  node_fqdn_label      = "cp-${tonumber(each.key) + 1}"
  cluster_fqdn         = local.cluster_fqdn
  cluster_fqdn_suffix  = local.fqdn_suffix
  node_role            = "server-join"
  control_plane_taint  = local.control_plane_taint
  cni                  = local.effective_cni
  registration_address = local.registration_address
  extra_tls_sans       = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  cluster_token        = random_password.server_token.result
  trusted_ca_pem       = var.trusted_ca_pem
  registry_mirror_url  = var.registry_mirror_url
  dns_servers          = var.dns_servers
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
  vpc_security_group_ids = [aws_security_group.node.id, aws_security_group.cluster.id, aws_security_group.control_plane_etcd.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # hop_limit 3, not AWS's generally-documented 2: confirmed live that 2 isn't enough for a
  # pod's IMDSv2 token PUT to complete through Cilium — see the genesis instance below.
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

  user_data_base64            = base64gzip(local.effective_user_data[each.key])
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-cp-${tonumber(each.key) + 1}" })

  depends_on = [aws_instance.control_plane]

  lifecycle {
    ignore_changes = [ami]
  }
}

# No registration endpoint for control_plane_count = 1. Internal NLB is the default HA mode
# on cloud (a floating VIP can't cross AZ boundaries); see endpoint_mode for dns/static.
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

# Route53's public health checkers can't reach a private VPC IP, so each health check is
# CLOUDWATCH_METRIC-type, backed by that instance's own EC2 status-check alarm — the
# standard bridge for private-IP Route53 failover.
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

# Inline JSON avoids a data.aws_iam_policy_document block that mock_provider cannot evaluate.
resource "aws_iam_role" "node" {
  name_prefix = local.node_iam_name_prefix
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
  name_prefix = local.node_iam_name_prefix
  role        = aws_iam_role.node.name
  tags        = local.common_tags
}

# Additional nodes (server-join) are provisioned below in aws_instance.control_plane_additional.
# The precondition fails plan explicitly when control_plane_count > 1 but fewer than 3 distinct
# AZs resolved, rather than silently under-spreading the quorum.
resource "aws_instance" "control_plane" {
  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = local.genesis_subnet_id
  vpc_security_group_ids = [aws_security_group.node.id, aws_security_group.cluster.id, aws_security_group.control_plane_etcd.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # hop_limit 3, not AWS's commonly-documented 2. Confirmed live: with hop_limit 2, a pod's
  # IMDSv2 token PUT completes its TCP handshake (proving pod<->host routing works) but the
  # token response never arrives ("Operation timed out ... 0 bytes received"). IMDSv2 caps
  # that response's TTL to hop_limit as an anti-SSRF control, and it's dropped one hop
  # short — Cilium's veth + pod-netns routing costs 2 hops here, not the 1 hop AWS's generic
  # guidance assumes. Mutable in place (not ForceNew) — no replacement needed to pick this up.
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

  user_data_base64            = base64gzip(local.effective_user_data["0"])
  user_data_replace_on_change = true # disposable nodes: replace on bootstrap change

  tags = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}" })

  # Marks every attached EBS volume (root + any CSI-provisioned data volumes)
  # delete-on-termination right before the instance is destroyed, so AWS cleans them up
  # without needing the API server/kubectl/SSM reachable at destroy time.
  #
  # Destroy-time provisioners may only reference `self` (Terraform rejects var./resource
  # references here to avoid destroy-order cycles) — region is derived from
  # self.availability_zone since var.aws_region isn't allowed.
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
      # EC2 rejects RunInstances over 16384 decoded bytes, and by then this plan has
      # created the role, the security groups and the token parameter. The payload's
      # size is not knowable until apply -- it carries a generated token -- so this
      # runs at apply and names the input that fixes it.
      condition     = var.bootstrap_payload_in_ssm || local.inline_user_data_bytes["0"] <= 16384
      error_message = "This node's boot payload is larger than EC2 allows in user data (16384 decoded bytes). Set bootstrap_payload_in_ssm = true to deliver it through SSM Parameter Store instead."
    }

    precondition {
      condition     = var.endpoint_mode != "dns" || (local.has_domain && local.effective_zone_id != null)
      error_message = "endpoint_mode = \"dns\" requires cluster_domain to be set and a resolvable hosted zone (hosted_zone_id or hosted_zone_name)."
    }
  }
}

# api.<cluster>.<domain>, always explicit rather than left to the wildcard above.
# DNS answers the most specific name, so this keeps pointing at the control plane
# even where external-dns has filled the wildcard with every worker's IP -- and a
# worker does not serve the API.
resource "aws_route53_record" "api" {
  count   = local.create_record ? 1 : 0
  zone_id = local.effective_zone_id
  name    = local.cluster_fqdn
  type    = "A"
  ttl     = 60
  records = [aws_instance.control_plane.private_ip]
}

# Created only when cluster_domain is set and a zone is resolvable. Otherwise register
# *.${cluster}.${domain} -> cluster_ip yourself using the wildcard_dns_name output.
resource "aws_route53_record" "wildcard" {
  count   = local.create_wildcard_record ? 1 : 0
  zone_id = local.effective_zone_id
  name    = local.wildcard_name
  type    = "A"
  ttl     = 60
  records = [aws_instance.control_plane.private_ip]
}
