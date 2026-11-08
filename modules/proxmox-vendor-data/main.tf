# SPDX-License-Identifier: Apache-2.0
# The journal is persistent so that the log of a boot that hangs survives a reset.
locals {
  cloud_config = {
    for key, value in {
      write_files = [{
        path    = "/etc/systemd/journald.conf.d/10-persistent.conf"
        content = "[Journal]\nStorage=persistent\n"
      }]
      ssh_authorized_keys = var.ssh_authorized_keys == null ? null : [for k in var.ssh_authorized_keys : trimspace(k)]
      runcmd = [
        "systemctl restart systemd-journald",
        "journalctl --flush",
        "systemctl enable --now qemu-guest-agent",
        "systemctl enable --now serial-getty@ttyS0.service",
      ]
    } : key => value if value != null
  }
}
