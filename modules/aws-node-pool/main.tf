# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  ami_arch         = contains(data.aws_ec2_instance_type.selected.supported_architectures, "arm64") ? "arm64" : "x86_64"
  effective_ami_id = var.os_image_ami_id != null ? var.os_image_ami_id : one(data.aws_ami.almalinux10[*].id)

  availability_zone = data.aws_subnet.selected.availability_zone

  # Connectivity-only user-data (mirrors aws-control-plane): enable the SSM Agent
  # so the operator's Ansible run can reach the instance. AlmaLinux AMIs "likely"
  # ship the agent pre-installed but not guaranteed running — enable/start
  # defensively, `|| true` so a genuinely-absent agent surfaces as a clear
  # Ansible connection error rather than a failed instance boot.
  connectivity_user_data = <<-EOT
    #!/bin/bash
    systemctl enable --now amazon-ssm-agent 2>/dev/null || true
  EOT

  # amazon.aws.aws_ssm's connection plugin mandatorily stages every file transfer
  # through an S3 bucket (no bucketless mode). The pool provisions its own so it
  # stays independently appliable — same shape as aws-control-plane's bucket.
  ansible_ssm_bucket_name = "kube-compute-${var.cluster_name}-worker-ansible-ssm-${data.aws_caller_identity.current.account_id}"

  # AWS-native token delivery: node-bootstrap runs this command on the node to
  # fetch the agent token from SSM at join time — the token is never embedded.
  agent_token_fetch_command = "aws ssm get-parameter --name '${var.agent_token_ssm_parameter}' --with-decryption --query Parameter.Value --output text --region ${var.aws_region}"

  node_labels = merge({ "topology.kubernetes.io/zone" = local.availability_zone }, var.extra_node_labels)

  # Falls back to the platform-wide default when the caller doesn't override k8s_version.
  k8s_version = coalesce(var.k8s_version, module.component_versions.k8s_version)

  common_tags = merge(var.extra_tags, {
    ClusterName = var.cluster_name
    ManagedBy   = "kube-compute"
  })

  # Fixed pool: one discrete instance per index (like proxmox-node-pool), so each
  # worker gets a stable node_name — unlike the old ASG, where Terraform never saw
  # individual instances and had to leave the name to the EC2 datasource.
  worker_indices = { for i in range(var.desired_count) : tostring(i) => i }
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

# ---- S3 staging bucket for amazon.aws.aws_ssm's Ansible connection plugin ----
# Mandatory infrastructure for the AWS transport (see the local above). Blocks all
# public access; SSE by default; a short lifecycle expiration since staged objects
# are transient per-task artifacts.
resource "aws_s3_bucket" "ansible_ssm" {
  bucket        = local.ansible_ssm_bucket_name
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "ansible_ssm" {
  bucket                  = aws_s3_bucket.ansible_ssm.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ansible_ssm" {
  bucket = aws_s3_bucket.ansible_ssm.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ansible_ssm" {
  bucket = aws_s3_bucket.ansible_ssm.id
  rule {
    id     = "expire-staged-objects"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

# Grants the worker's IAM role read/write on the staging bucket — the SSM Agent on
# the instance uploads/downloads through this bucket during a session.
resource "aws_iam_role_policy" "ansible_ssm_s3" {
  name = "kube-compute-${var.cluster_name}-worker-ansible-ssm-s3"
  role = aws_iam_role.worker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:GetEncryptionConfiguration"]
        Resource = ["${aws_s3_bucket.ansible_ssm.arn}", "${aws_s3_bucket.ansible_ssm.arn}/*"]
      }
    ]
  })
}

# ---- Fixed node pool: discrete EC2 instances, one per index, all in the pool's AZ ----
resource "aws_instance" "worker" {
  count = var.desired_count

  ami                    = local.effective_ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.worker.name
  vpc_security_group_ids = [var.cluster_security_group_id]
  user_data              = local.connectivity_user_data

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
  }

  tags = merge(local.common_tags, { Name = "kube-compute-${var.cluster_name}-worker-${count.index}" })
}

# ---- Per-instance Ansible worker join, over SSM (no inbound port) ----
# One node-bootstrap run per discrete instance, connecting via amazon.aws.aws_ssm —
# the same transport aws-control-plane uses. Each worker fetches its own agent
# token independently and RKE2's agent natively retries the join, so there is no
# etcd-learner race to stagger (unlike additional control-plane servers).
module "node_bootstrap" {
  for_each = local.worker_indices

  source = "../node-bootstrap"

  ansible_playbook_path     = var.ansible_playbook_path
  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-worker-${each.key}"
  k8s_version               = local.k8s_version
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = local.node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url

  ansible_connection_vars = {
    ansible_connection          = "amazon.aws.aws_ssm"
    ansible_aws_ssm_instance_id = aws_instance.worker[each.value].id
    ansible_aws_ssm_region      = var.aws_region
    ansible_aws_ssm_bucket_name = aws_s3_bucket.ansible_ssm.id
    # Pinned rather than auto-discovered: every node is AlmaLinux 10, whose
    # /usr/bin/python3 is a stable symlink to the current default Python.
    ansible_python_interpreter = "/usr/bin/python3"
  }
}
