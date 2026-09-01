# SPDX-License-Identifier: Apache-2.0

# Shells out to nsupdate rather than using the hashicorp/dns provider: a real
# apply against Technitium found every dynamic update sent by that provider
# (add and delete alike) rejected with "NOTIMP", while the byte-for-byte
# equivalent operation via nsupdate succeeded every time, including
# node-bootstrap's own genesis self-registration (which already shells out to
# nsupdate for the same reason — see that module's bootstrap.sh.tftpl). Root
# cause not pinned down beyond "something in that provider's RFC2136 wire
# encoding" — not worth chasing further when nsupdate is proven reliable.
# Requires nsupdate (bind-utils/dnsutils) on the machine running `tofu apply`.
locals {
  # Same derivation as node-bootstrap's local.nsupdate_flags: -v forces TCP,
  # -4/-6 pin the address family.
  nsupdate_flags = trimspace(join(" ", compact([
    startswith(var.dns_transport, "tcp") ? "-v" : "",
    endswith(var.dns_transport, "4") ? "-4" : "",
    endswith(var.dns_transport, "6") ? "-6" : "",
  ])))
}

# One record set, every address under the same name — not one record per
# address. Sufficient because RKE2 agents self-discover peers after their
# first join, and kubectl already retries sequentially across resolved
# addresses; no health-checked updates needed.
#
# tsig_key_secret is deliberately NOT part of `input`: terraform_data persists
# `input`/`output` to state, and this project's hard rule is that secrets
# never touch state in plaintext. The create-time provisioner passes it via
# its own `environment` block instead (evaluated at apply time, never written
# into any resource attribute) — but OpenTofu's destroy-time provisioners
# reject ANY reference outside `self`/`count.index`/`each.key`, full stop, even
# a plain leaf variable with no resource dependency (confirmed the hard way:
# `tofu init` refuses to even validate a destroy provisioner's `environment`
# block referencing `var.tsig_key_secret`). So the destroy-time script below
# reads the secret straight from its inherited process environment
# (`TF_VAR_tsig_key_secret`) instead of through any Terraform-evaluated
# reference — the same env var every caller in this project already sets to
# supply this value to `tofu` itself, so it's always present whenever a
# `tofu destroy` that could reach this provisioner is running. This does mean
# the destroy path trusts that literal env var name rather than whatever
# `var.tsig_key_secret` was actually wired to — acceptable since every known
# caller sets both the same way, but worth knowing if a future caller ever
# sources tsig_key_secret differently.
resource "terraform_data" "this" {
  count = var.enabled ? 1 : 0

  input = {
    dns_zone           = var.dns_zone
    record_name        = var.record_name
    record_addresses   = var.record_addresses
    record_ttl         = var.record_ttl
    dns_server_address = var.dns_server_address
    dns_server_port    = var.dns_server_port
    nsupdate_flags     = local.nsupdate_flags
    tsig_key_name      = var.tsig_key_name
    tsig_key_algorithm = var.tsig_key_algorithm
  }

  # Any change to the inputs above should re-publish the record, but
  # terraform_data only re-runs its create-time provisioner on actual
  # creation, not on an in-place update — force a replace (destroy + create)
  # instead so an address/TTL/zone change reliably reruns nsupdate.
  triggers_replace = [
    var.dns_zone,
    var.record_name,
    var.record_addresses,
    var.record_ttl,
    var.dns_server_address,
    var.dns_server_port,
    var.dns_transport,
    var.tsig_key_name,
    var.tsig_key_algorithm,
  ]

  provisioner "local-exec" {
    environment = {
      TSIG_KEY_SECRET = var.tsig_key_secret
    }
    command = <<-EOT
      set -euo pipefail
      if ! command -v nsupdate >/dev/null 2>&1; then
        echo "dns-registration: nsupdate not found — install bind-utils (RHEL/Alma) or dnsutils (Debian/Ubuntu) on the machine running 'tofu apply'" >&2
        exit 1
      fi
      umask 077
      KEYFILE="$(mktemp)"
      trap 'rm -f "$KEYFILE"' EXIT
      {
        echo "key \"${self.output.tsig_key_name}\" {"
        echo "  algorithm ${self.output.tsig_key_algorithm};"
        echo "  secret \"$TSIG_KEY_SECRET\";"
        echo "};"
      } > "$KEYFILE"
      {
        echo "server ${self.output.dns_server_address} ${self.output.dns_server_port}"
        echo "zone ${self.output.dns_zone}"
        echo "update delete ${self.output.record_name}.${self.output.dns_zone} A"
      %{for addr in self.output.record_addresses~}
        echo "update add ${self.output.record_name}.${self.output.dns_zone} ${self.output.record_ttl} A ${addr}"
      %{endfor~}
        echo "send"
      } | nsupdate ${self.output.nsupdate_flags} -k "$KEYFILE"
    EOT
  }

  provisioner "local-exec" {
    when = destroy

    command = <<-EOT
      set -euo pipefail
      if ! command -v nsupdate >/dev/null 2>&1; then
        echo "dns-registration: nsupdate not found — cannot clean up ${self.output.record_name}.${self.output.dns_zone}, remove it manually" >&2
        exit 0
      fi
      if [ -z "$${TF_VAR_tsig_key_secret:-}" ]; then
        echo "dns-registration: TF_VAR_tsig_key_secret not set in this shell — cannot clean up ${self.output.record_name}.${self.output.dns_zone}, remove it manually" >&2
        exit 0
      fi
      umask 077
      KEYFILE="$(mktemp)"
      trap 'rm -f "$KEYFILE"' EXIT
      {
        echo "key \"${self.output.tsig_key_name}\" {"
        echo "  algorithm ${self.output.tsig_key_algorithm};"
        echo "  secret \"$${TF_VAR_tsig_key_secret}\";"
        echo "};"
      } > "$KEYFILE"
      {
        echo "server ${self.output.dns_server_address} ${self.output.dns_server_port}"
        echo "zone ${self.output.dns_zone}"
        echo "update delete ${self.output.record_name}.${self.output.dns_zone} A"
        echo "send"
      } | nsupdate ${self.output.nsupdate_flags} -k "$KEYFILE"
    EOT
  }
}
