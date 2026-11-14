# SPDX-License-Identifier: Apache-2.0
# The boot steps that only a Proxmox node needs. They are cloud-init files and commands
# for node-bootstrap's provider_steps and provider_files inputs. This module renders text
# and creates nothing.
locals {
  initiator_name = "iqn.2026.lan.${var.cluster_name}:${coalesce(var.node_fqdn_label, var.node_name)}"

  dns_self_register_enabled = var.dns_self_register_zone != null && var.dns_self_register_zone != ""

  # nsupdate's `zone` directive requires a fully-qualified (trailing-dot) name, but
  # callers commonly pass a bare zone (e.g. "lan"). Either form works here.
  dns_zone = local.dns_self_register_enabled ? "${trimsuffix(var.dns_self_register_zone, ".")}." : ""

  # nsupdate transport flags: -v forces TCP, -4/-6 pin the address family.
  nsupdate_flags = trimspace(join(" ", compact([
    startswith(var.dns_transport, "tcp") ? "-v" : "",
    endswith(var.dns_transport, "4") ? "-4" : "",
    endswith(var.dns_transport, "6") ? "-6" : "",
  ])))

  nsupdate_key_path     = "/run/kube-compute-nsupdate.key"
  nsupdate_request_path = "/run/kube-compute-nsupdate.txt"

  # A TSIG keyfile, and not nsupdate's -y form, keeps the secret out of
  # /proc/<pid>/cmdline, which any local user can read.
  nsupdate_key = <<-EOT
    key "${coalesce(var.tsig_key_name, "unused")}" {
      algorithm ${var.tsig_key_algorithm};
      secret "${coalesce(var.tsig_key_secret, "unused")}";
    };
  EOT

  # @NODE_IP@ is replaced on the node, which is the only place that knows its IP.
  nsupdate_request = <<-EOT
    server ${coalesce(var.dns_server_address, "unused")} ${var.dns_server_port}
    zone ${local.dns_zone}
    update delete ${coalesce(var.dns_self_register_record_name, "unused")}.${local.dns_zone} A
    update add ${coalesce(var.dns_self_register_record_name, "unused")}.${local.dns_zone} ${var.dns_self_register_ttl} A @NODE_IP@
    send
  EOT

  # Publishes a single-target A record as soon as the node knows its own IP, so a
  # concurrently-bootstrapping sibling never has to wait for the round-robin api.* record
  # every control-plane node contributes to. The key and the request are removed whether
  # or not nsupdate succeeds. runcmd does not stop at a failed command, so a failure
  # leaves a marker file and the boot program stops on it.
  dns_self_register_script = <<-EOT
    set -eu
    trap 'rc=$?; rm -f ${local.nsupdate_key_path} ${local.nsupdate_request_path}; [ "$rc" -eq 0 ] || touch /run/kube-compute-step-failed' EXIT
    NODE_IP=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
    test -n "$NODE_IP"
    sed "s/@NODE_IP@/$NODE_IP/" ${local.nsupdate_request_path} | nsupdate ${local.nsupdate_flags} -k ${local.nsupdate_key_path}
  EOT

  # The iSCSI file replaces the OS-generated random InitiatorName with one derived from
  # the node's identity, so the target-side allow-list is registered once, ahead of time.
  steps = concat(
    var.iscsi_initiator_enabled ? [{ name = "iscsi-initiator", commands = [["systemctl", "restart", "iscsid"]] }] : [],
    local.dns_self_register_enabled ? [{ name = "dns-self-register", commands = [["/bin/sh", "-c", local.dns_self_register_script]] }] : [],
  )

  files = concat(
    var.iscsi_initiator_enabled ? [{
      path        = "/etc/iscsi/initiatorname.iscsi"
      content     = "InitiatorName=${local.initiator_name}\n"
      permissions = "0644"
    }] : [],
    !local.dns_self_register_enabled ? [] : [
      { path = local.nsupdate_key_path, content = local.nsupdate_key, permissions = "0600" },
      { path = local.nsupdate_request_path, content = local.nsupdate_request, permissions = "0600" },
    ],
  )
}
