# SPDX-License-Identifier: Apache-2.0
variable "ssh_authorized_keys" {
  description = "SSH public keys for the default cloud user. Null writes no ssh_authorized_keys key."
  type        = list(string)
  default     = null
}
