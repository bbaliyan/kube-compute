# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../cloud-init/templates/cloud-init-al2023.yaml.tpl")

  ami_arch         = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"
  effective_ami_id = var.os_image_ami_id != null ? var.os_image_ami_id : one(data.aws_ami.al2023[*].id)

  availability_zone = data.aws_subnet.selected.availability_zone

  # AWS-native delivery for this provider module: cloud-init only ever sees an
  # opaque command it executes at boot, never the SSM API itself.
  agent_token_fetch_command = "aws ssm get-parameter --name '${var.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  node_labels = merge({ "topology.kubernetes.io/zone" = local.availability_zone }, var.extra_node_labels)

  # Version-skew check: kubelet may trail the API server, never lead it. k8s_version is
  # "vMAJOR.MINOR.PATCH+k3sN"; only major/minor/patch are compared numerically.
  version_regex       = "^v(\\d+)\\.(\\d+)\\.(\\d+)\\+"
  pool_version_parts  = regex(local.version_regex, var.k8s_version)
  spine_version_parts = regex(local.version_regex, var.spine_k8s_version)
  pool_version_num    = tonumber(local.pool_version_parts[0]) * 1000000 + tonumber(local.pool_version_parts[1]) * 1000 + tonumber(local.pool_version_parts[2])
  spine_version_num   = tonumber(local.spine_version_parts[0]) * 1000000 + tonumber(local.spine_version_parts[1]) * 1000 + tonumber(local.spine_version_parts[2])

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })
}

module "bootstrap" {
  source = "../cloud-init"

  # node_name deliberately omitted: this one cloud-init payload is shared by
  # every instance the ASG creates (Terraform never sees individual
  # instances), so there's no static per-instance name to assign here. Leaving
  # it null lets cloud-init's EC2 datasource assign its own naturally-unique
  # per-instance hostname instead of every instance colliding on the same one.
  cloud_init_template       = local.cloud_init_template
  cluster_name              = var.cluster_name
  k8s_version               = var.k8s_version
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  extra_tags                = var.extra_tags
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

# ---- Fixed worker pool: ASG + launch template ----
resource "aws_launch_template" "worker" {
  name_prefix   = "kube-compute-${var.cluster_name}-worker-"
  image_id      = local.effective_ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.worker.name
  }

  vpc_security_group_ids = [var.cluster_security_group_id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 2
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

  user_data = module.bootstrap.user_data_base64

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-worker" })
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = local.pool_version_num <= local.spine_version_num
      error_message = "k8s_version (${var.k8s_version}) must not be newer than the spine's k8s_version (${var.spine_k8s_version}) — a kubelet may trail the API server by up to 3 minors, never lead it."
    }
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
