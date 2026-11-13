# SPDX-License-Identifier: Apache-2.0

variable "name_prefix" {
  description = "Name prefix of the IAM role and the instance profile. AWS caps it at 38 characters."
  type        = string
}

variable "tags" {
  description = "Tags for the IAM role and the instance profile."
  type        = map(string)
}

variable "aws_region" {
  description = "Region of the agent token parameter."
  type        = string
}

variable "attach_ebs_csi_policy" {
  description = "Attach AmazonEBSCSIDriverPolicy to the role."
  type        = bool
  default     = true
}

variable "agent_token" {
  description = "Lets the role read one agent token parameter: the policy name and the parameter name. Null creates no policy."
  type = object({
    policy_name   = string
    ssm_parameter = string
  })
  default = null
}
