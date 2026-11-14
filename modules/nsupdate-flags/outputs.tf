# SPDX-License-Identifier: Apache-2.0
output "flags" {
  description = "The nsupdate command-line flags for the transport. Empty for plain UDP."
  value       = local.flags
}
