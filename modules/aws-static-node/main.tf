# SPDX-License-Identifier: Apache-2.0
# A group of NAMED worker instances, not an autoscaling group. aws-node-pool is
# the ASG path and stays where it is; this module exists because three things a
# fixed-size cluster needs are not obtainable from a group:
#
#   1. A stop schedule. An ASG's health check treats an instance that is not
#      running as failed and replaces it, so a nightly ec2:StopInstances against
#      a group member is undone within minutes. Stopping a group means Standby or
#      a desired capacity of zero -- a different API, a different IAM action, and
#      a different thing to reverse in the morning.
#   2. A stable instance id. Per-instance IAM scoping (the stop schedule's own
#      policy is written against instance ARNs) and SSM targeting both need an id
#      that survives a reboot. An ASG hands out a new one on every replacement.
#   3. A distinct hostname per node, assigned by Terraform rather than by
#      cloud-init's EC2 datasource. Every ASG member shares one launch template
#      and therefore one rendered cloud-init, which is why aws-node-pool must
#      pass set_hostname = false. Here each node gets its own render, so its
#      Kubernetes node name is a name a human chose.
#
# What is given up in exchange: nothing reacts to load, and nothing replaces a
# failed node. That is the correct trade for a cluster whose node roles are
# decided in Git; see README.md.
locals {
  ami_arch = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"

  effective_ami_id = coalesce(
    var.os_image_ami_id,
    try(one(data.aws_ami.by_name[*].id), null),
    try(one(data.aws_ami.almalinux10[*].id), null),
  )

  availability_zone = data.aws_subnet.selected.availability_zone

  # Keys are "1".."node_count" so instance names read <cluster>-<group>-1 rather
  # than starting at zero, matching aws-control-plane's own cp-1/cp-2 naming.
  node_keys = { for i in range(var.node_count) : tostring(i + 1) => i + 1 }

  node_names = { for k, _ in local.node_keys : k => "${var.cluster_name}-${var.group_name}-${k}" }

  # AlmaLinux community AMIs "likely" ship SSM Agent pre-installed but not
  # guaranteed running -- enable/start defensively, mirroring the identical
  # local in aws-control-plane and aws-node-pool. SSM is the only operator
  # access path in this project; there is no inbound SSH anywhere.
  connectivity_user_data = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  # AWS accepts one user_data string per instance, so MIME multipart/mixed
  # combines the SSM-enable script with node-bootstrap's #cloud-config payload
  # without decoding and re-merging the YAML (which would couple this module to
  # node-bootstrap's internal shape). Keyed per node, since unlike the ASG path
  # each node has its own payload.
  mime_boundary = "MIMEBOUNDARY"

  combined_user_data = {
    for k, m in module.node_bootstrap : k => join("\n", [
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
      m.cloud_init_user_data,
      "--${local.mime_boundary}--",
      "",
    ])
  }

  # AWS-native token delivery: node-bootstrap runs this on the node to fetch the
  # agent token from SSM at join time. The token is never in user_data, which is
  # readable by anything that reaches the instance metadata service.
  agent_token_fetch_command = "aws ssm get-parameter --name '${var.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  # kube-compute.io/node-group is set from group_name unconditionally so a
  # workload can select this group without the caller having to remember to pass
  # a label that duplicates the name it already gave. The AZ label matches
  # aws-node-pool's own.
  node_labels = merge(
    {
      "topology.kubernetes.io/zone" = local.availability_zone
      "kube-compute.io/node-group"  = var.group_name
    },
    var.node_labels,
  )

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    NodeGroup   = var.group_name
    ManagedBy   = "kube-compute"
  })
}

# One role per GROUP, not per node: a role per instance would multiply for no
# gain, since every node in a group reads the same one SSM parameter and needs
# the same one managed policy.
resource "aws_iam_role" "node" {
  name_prefix = "kube-compute-${var.cluster_name}-${var.group_name}-"
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

# See the attach_ebs_csi_policy variable for why this defaults on: the CSI
# controller is an ordinary Deployment and lands wherever the scheduler puts it.
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.attach_ebs_csi_policy ? 1 : 0
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Inline JSON avoids a data.aws_iam_policy_document block that mock_provider
# cannot evaluate.
resource "aws_iam_role_policy" "agent_token" {
  name = "kube-compute-${var.cluster_name}-${var.group_name}-agent-token-read"
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameter"
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.agent_token_ssm_parameter}"
      },
      {
        Effect = "Allow"
        Action = "kms:Decrypt"
        # Scoped by condition, not resource: the default SSM-managed key
        # (alias/aws/ssm) has no fixed ARN this module can name ahead of time.
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com"
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "kube-compute-${var.cluster_name}-${var.group_name}-"
  role        = aws_iam_role.node.name
  tags        = local.common_tags
}

# One render per node, which is what makes set_hostname = true viable here (the
# ASG path cannot: see the header comment). node_fqdn_label drops the cluster
# prefix from the DNS label, since cluster_fqdn_suffix already carries the
# cluster identity -- same split aws-control-plane makes for its cp-N nodes.
module "node_bootstrap" {
  source   = "../node-bootstrap"
  for_each = local.node_keys

  cluster_name              = var.cluster_name
  node_name                 = local.node_names[each.key]
  node_fqdn_label           = "${var.group_name}-${each.key}"
  cluster_fqdn_suffix       = var.cluster_fqdn_suffix
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  node_taints               = var.node_taints
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  dns_servers               = var.dns_servers
}

# No depends_on against the control plane: node-bootstrap renders a plan-time
# payload with no live connection to wait on, and RKE2's agent retries its join
# indefinitely, so a worker booting alongside genesis simply waits. The caller
# passes registration_address, which already carries the ordering Terraform can
# see.
resource "aws_instance" "node" {
  for_each = local.node_keys

  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # hop_limit 3, not AWS's generally-documented 2. Confirmed live on this
  # project's control-plane node that 2 is one hop short of a pod's IMDSv2 token
  # PUT getting its response back: IMDSv2 caps the response TTL to hop_limit as
  # an anti-SSRF control, and Cilium's veth + pod-netns routing costs 2 hops, not
  # the 1 AWS's generic guidance assumes. Workers run the same CNI path.
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
    tags                  = merge(local.common_tags, { Name = "${local.node_names[each.key]}-root" })
  }

  user_data_base64            = base64gzip(local.combined_user_data[each.key])
  user_data_replace_on_change = true

  tags = merge(local.common_tags, { Name = local.node_names[each.key] })

  lifecycle {
    # Don't replace on AlmaLinux 10 AMI patch drift; remove to deliberately
    # upgrade, same as the control plane.
    ignore_changes = [ami]
  }
}
