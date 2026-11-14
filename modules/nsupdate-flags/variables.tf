# SPDX-License-Identifier: Apache-2.0
variable "transport" {
  description = "Transport for the dynamic update: 'udp', 'tcp', 'udp4', 'udp6', 'tcp4', or 'tcp6'."
  type        = string
  validation {
    condition     = contains(["udp", "tcp", "udp4", "udp6", "tcp4", "tcp6"], var.transport)
    error_message = "transport must be one of: udp, tcp, udp4, udp6, tcp4, tcp6."
  }
}
