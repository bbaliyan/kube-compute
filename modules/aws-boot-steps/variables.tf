# SPDX-License-Identifier: Apache-2.0
variable "aws_provider_id" {
  description = "Registers the node with providerID aws:///<zone>/<instance-id> and the label node.kubernetes.io/instance-type, both read from EC2 metadata before RKE2 starts. cluster-autoscaler and the AWS cloud controller manager find the instance by providerID."
  type        = bool
  default     = false
}

variable "pod_identity_enabled" {
  description = "Always register the node with its providerID and label it with its zone, region and instance type, read from EC2 metadata before RKE2 starts. The EBS CSI driver reads them from the node, so it needs no metadata service. Implies aws_provider_id."
  type        = bool
  default     = false
}
