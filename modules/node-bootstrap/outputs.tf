# SPDX-License-Identifier: Apache-2.0
output "bootstrap_id" {
  description = "The triggering null_resource's id. Depend on this (not just the module call) when another resource must wait for this node's Ansible run to complete, e.g. a load-balancer target-group attachment that should only register a node once it has actually joined."
  value       = null_resource.ansible_bootstrap.id
}

output "bootstrap_log_path" {
  description = "Local path (on whatever machine runs terragrunt apply) where this node's Ansible run output is mirrored, live, via tee. Terraform/OpenTofu unconditionally suppresses this provisioner's own console output because the resource's config touches sensitive values (cluster tokens) — tail -f this file from a second terminal for real-time bootstrap progress during a long apply instead."
  value       = "/tmp/kube-compute-bootstrap-${var.node_name}.log"
}
