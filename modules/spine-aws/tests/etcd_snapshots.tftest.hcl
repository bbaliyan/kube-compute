# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/cp-lb-mock/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/cp-tg-mock/1234567890123456" }
  }
}

run "single_node_snapshots_off_by_default" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.rendered_cloud_init), "--etcd-snapshot-schedule-cron")
    error_message = "single-node (control_plane_count=1) must default etcd snapshots off"
  }
}

run "ha_snapshots_on_by_default" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    control_plane_count   = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "--etcd-snapshot-schedule-cron")
    error_message = "HA (control_plane_count>1) must default etcd snapshots on"
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init_additional["1"]), "--etcd-snapshot-schedule-cron")
    error_message = "additional control-plane nodes must render the same snapshot schedule as the genesis node"
  }
}

run "explicit_false_overrides_ha_default" {
  command = apply
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
    control_plane_count   = 3
    control_plane_subnets = {
      "eu-west-1a" = "subnet-az-a"
      "eu-west-1b" = "subnet-az-b"
      "eu-west-1c" = "subnet-az-c"
    }
    etcd_snapshots_enabled = false
  }
  assert {
    condition     = !strcontains(nonsensitive(output.rendered_cloud_init), "--etcd-snapshot-schedule-cron")
    error_message = "an explicit etcd_snapshots_enabled=false must override the HA auto-default"
  }
}

run "single_node_snapshots_still_off_by_default_even_with_bucket" {
  command = plan
  variables {
    cluster_name            = "bharat"
    aws_region              = "eu-west-1"
    instance_type           = "m7g.large"
    allowed_ingress_cidrs   = ["10.0.0.0/8"]
    subnet_id               = "subnet-abc"
    etcd_snapshot_s3_bucket = "kube-node-bharat-snapshots"
  }
  assert {
    condition     = !strcontains(nonsensitive(module.bootstrap.cloud_init), "--etcd-snapshot-schedule-cron")
    error_message = "control_plane_count=1 must keep snapshots off by default even when an object-store bucket is configured — only an explicit etcd_snapshots_enabled=true turns them on for single-node"
  }
}

run "object_store_bucket_grants_scoped_iam_and_renders_s3_flags" {
  command = apply
  variables {
    cluster_name            = "bharat"
    aws_region              = "eu-west-1"
    instance_type           = "m7g.large"
    allowed_ingress_cidrs   = ["10.0.0.0/8"]
    subnet_id               = "subnet-abc"
    etcd_snapshot_s3_bucket = "kube-node-bharat-snapshots"
    etcd_snapshots_enabled  = true
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "--etcd-s3-bucket kube-node-bharat-snapshots")
    error_message = "etcd_snapshot_s3_bucket must render as --etcd-s3-bucket in the genesis node's cloud-init"
  }
  assert {
    condition     = strcontains(nonsensitive(output.rendered_cloud_init), "--etcd-s3-region eu-west-1")
    error_message = "etcd_snapshot_s3_region must default to aws_region when a bucket is given but no region is set explicitly"
  }
  assert {
    condition     = length(aws_iam_role_policy.etcd_snapshot_s3) == 1
    error_message = "a bucket must grant a scoped IAM policy on the control-plane role"
  }
  assert {
    condition     = strcontains(nonsensitive(aws_iam_role_policy.etcd_snapshot_s3[0].policy), "kube-node-bharat-snapshots")
    error_message = "the IAM policy must reference the specific bucket, not a wildcard"
  }
}

run "no_bucket_grants_no_iam_policy" {
  command = plan
  variables {
    cluster_name          = "bharat"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-abc"
  }
  assert {
    condition     = length(aws_iam_role_policy.etcd_snapshot_s3) == 0
    error_message = "no bucket configured must mean no S3 IAM policy is created"
  }
}
