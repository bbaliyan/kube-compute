# SPDX-License-Identifier: Apache-2.0
# The one place that maps a transport to nsupdate flags. dns-registration runs nsupdate
# from the operator machine and proxmox-boot-steps runs it on the node. -v forces TCP,
# and -4 or -6 pins the address family.
locals {
  flags = trimspace(join(" ", compact([
    startswith(var.transport, "tcp") ? "-v" : "",
    endswith(var.transport, "4") ? "-4" : "",
    endswith(var.transport, "6") ? "-6" : "",
  ])))
}
