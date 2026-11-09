# SPDX-License-Identifier: Apache-2.0
variable "aws_provider_id" {
  description = "Registers the node with providerID aws:///<zone>/<instance-id> and labels it node.kubernetes.io/instance-type, both read from EC2 instance metadata before RKE2 starts. cluster-autoscaler and the AWS cloud controller manager find a node's instance by the providerID. Any role takes the label, control plane included."
  type        = bool
  default     = false
}
