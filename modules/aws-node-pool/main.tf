# SPDX-License-Identifier: Apache-2.0
locals {
  ami_arch         = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"
  effective_ami_id = var.os_image_ami_id != null ? var.os_image_ami_id : one(data.aws_ami.almalinux10[*].id)

  availability_zone = data.aws_subnet.selected.availability_zone

  # AWS's own docs list AlmaLinux among AMIs that "likely" ship the SSM Agent
  # pre-installed but not guaranteed running — enable/start defensively (mirrors
  # aws-control-plane's identical local). Kept independent of RKE2/node-bootstrap:
  # SSM is this pool's ongoing operator-access path, not merely a bootstrap-time
  # transport, so it stays enabled even though nothing runs live Ansible over it.
  connectivity_user_data = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  # AWS accepts only one user_data string per instance. Cloud-init's own MIME
  # multipart/mixed convention combines this AWS-only SSM-agent-enable script with
  # node-bootstrap's #cloud-config payload — same approach as aws-control-plane,
  # see that module's identical local for the full reasoning. Every ASG instance
  # gets the exact same rendered document (the launch template's user_data), which
  # is why node-bootstrap is called below with set_hostname = false: cloud-init's
  # EC2 datasource assigns each instance its own naturally-unique hostname when
  # cloud-config doesn't set one explicitly (the same behavior this pool relied on
  # before the Ansible-bootstrap swap turned it into discrete per-instance renders).
  mime_boundary = "MIMEBOUNDARY"

  combined_user_data = join("\n", [
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
    module.node_bootstrap.cloud_init_user_data,
    "--${local.mime_boundary}--",
    "",
  ])

  # AWS-native token delivery: node-bootstrap runs this command on the node to
  # fetch the agent token from SSM at join time — the token is never embedded.
  agent_token_fetch_command = "aws ssm get-parameter --name '${var.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  node_labels = merge({ "topology.kubernetes.io/zone" = local.availability_zone }, var.extra_node_labels)

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })
}

# ---- IAM: SSM-managed instance, scoped to read only this cluster's agent token ----
resource "aws_iam_role" "worker" {
  name_prefix = "kube-compute-${var.cluster_name}-worker-"
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

resource "aws_iam_role_policy_attachment" "worker_ssm_core" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Inline JSON avoids a data.aws_iam_policy_document block that mock_provider cannot evaluate.
resource "aws_iam_role_policy" "worker_agent_token" {
  name = "kube-compute-${var.cluster_name}-agent-token-read"
  role = aws_iam_role.worker.id
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
        # Scoped by condition, not resource: the default SSM-managed key (alias/aws/ssm)
        # has no fixed ARN this module can name ahead of time.
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

resource "aws_iam_instance_profile" "worker" {
  name_prefix = "kube-compute-${var.cluster_name}-worker-"
  role        = aws_iam_role.worker.name
  tags        = local.common_tags
}

# ---- Shared worker join payload: one node-bootstrap render for the whole pool ----
# The ASG's launch template hands every instance it creates the exact same
# user_data — Terraform never sees individual pool members, so there is no
# per-instance node_name to assign (unlike aws-control-plane's discrete control-plane
# nodes). set_hostname = false omits node-bootstrap's own hostname/fqdn cloud-config
# keys for exactly this reason; node_name below is passed only for node-bootstrap's
# node_name output (unused here) and carries no cloud-config effect. RKE2's agent
# process natively retries the join, so there is no etcd-learner-style race to
# stagger between workers the way there is between additional control-plane nodes.
module "node_bootstrap" {
  source = "../node-bootstrap"

  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-worker"
  set_hostname              = false
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
}

# ---- Fixed node pool: ASG + launch template, no scaling policies ----
# min_size = max_size = desired_capacity — deliberately inert until a chosen
# autoscaler is wired up to drive it (kube-image-design Ticket 07's locked shape).
# Buys self-healing (ASG replaces a terminated instance) and rolling launch-template
# updates for free; nothing here reacts to load.
resource "aws_launch_template" "worker" {
  name_prefix   = "kube-compute-${var.cluster_name}-worker-"
  image_id      = local.effective_ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.worker.name
  }

  vpc_security_group_ids = [var.cluster_security_group_id]

  # hop_limit 3: confirmed live on aws-control-plane's node that 2 isn't enough
  # for a pod's IMDSv2 token PUT to get its response back through Cilium (TCP
  # handshake completes, response dropped as TTL-exceeded one hop short) — see
  # aws-control-plane/main.tf's genesis instance for the full story. Applied here
  # too since worker nodes run the same CNI/pod-network path.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 3
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = var.root_volume_type
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  # aws_launch_template's user_data expects an already-base64-encoded value
  # (unlike aws_instance's plain user_data), so base64gzip() here is not merely a
  # size optimization — it also satisfies the field's encoding requirement.
  user_data = base64gzip(local.combined_user_data)

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-worker" })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "worker" {
  name_prefix         = "kube-compute-${var.cluster_name}-worker-"
  min_size            = var.desired_count
  max_size            = var.desired_count
  desired_capacity    = var.desired_count
  vpc_zone_identifier = [var.subnet_id]

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "kube-compute-${var.cluster_name}-worker"
    propagate_at_launch = true
  }
  tag {
    key                 = "ClusterName"
    value               = var.cluster_name
    propagate_at_launch = true
  }
}
