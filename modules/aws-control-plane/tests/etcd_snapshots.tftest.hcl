# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:loadbalancer/net/cp-lb-mock/1234567890123456" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:eu-west-1:123456789012:targetgroup/cp-tg-mock/1234567890123456" }
  }
}

# NOTE: single_node_snapshots_off_by_default, ha_snapshots_on_by_default,
# explicit_false_overrides_ha_default, and single_node_snapshots_still_off_by_default_even_with_bucket
# used to live here, asserting on `rendered_cloud_init`/`rendered_cloud_init_additional`
# (or, in the last case, a stale `module.bootstrap.cloud_init` reference from before the
# node-bootstrap rename). Those outputs no longer exist — the etcd-snapshot
# enabled/schedule content is now handed to `node-bootstrap`, which renders it via
# Ansible at real-apply time, not into a Terraform-visible string. The IAM-policy-only
# assertions below remain (they test this module's own wiring, not rendered content).
# See rke2-ansible-bootstrap Ticket 14's resolution notes for the coverage gap this
# leaves (single-node-vs-HA snapshot-enabled default, explicit-override).

run "object_store_bucket_grants_scoped_iam_and_renders_s3_flags" {
  command = plan
  variables {
    cluster_name            = "bharat"
    aws_region              = "eu-west-1"
    instance_type           = "m7g.large"
    allowed_ingress_cidrs   = ["10.0.0.0/8"]
    subnet_id               = "subnet-abc"
    etcd_snapshot_s3_bucket = "kube-compute-bharat-snapshots"
    etcd_snapshots_enabled  = true
  }
  assert {
    condition     = length(aws_iam_role_policy.etcd_snapshot_s3) == 1
    error_message = "a bucket must grant a scoped IAM policy on the control-plane role"
  }
  assert {
    condition     = strcontains(nonsensitive(aws_iam_role_policy.etcd_snapshot_s3[0].policy), "kube-compute-bharat-snapshots")
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
