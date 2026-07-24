# SPDX-License-Identifier: Apache-2.0
output "bootstrap_id" {
  description = "The triggering null_resource's id. Depend on this (not just the module call) when another resource must wait for this node's Ansible run to complete, e.g. a load-balancer target-group attachment that should only register a node once it has actually joined."
  value       = null_resource.ansible_bootstrap.id
}
