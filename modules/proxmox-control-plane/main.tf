# SPDX-License-Identifier: Apache-2.0
locals {
  # Naming convention only — node-pool computes the identical formula from its own
  # cluster_name to reference this module's ipset by name, with no Terraform
  # dependency between the two modules. This module owns the ipset resources;
  # node-pool never creates one.
  cluster_ipset_name = "kube-compute-${var.cluster_name}-cluster"
  etcd_ipset_name    = "kube-compute-${var.cluster_name}-etcd"

  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null

  # Join address for additional-CP joins (module.node_bootstrap_additional below). A
  # single-target DNS name — distinct from cluster_fqdn's round-robin api.* record.
  # Genesis self-registers this via node-bootstrap's dns_self_register_* inputs as
  # soon as it knows its own IP, so it's a zero-dependency string when DNS is
  # configured; falls back to genesis's raw IP (a real resource dependency) when
  # dns_server_address is null.
  genesis_dns_name = local.has_domain ? "genesis.${var.cluster_name}.${trimsuffix(var.cluster_domain, ".")}" : null
  # Deliberately NOT local.cp_ips["0"]: cp_ips is a merged map built from BOTH
  # control_plane and control_plane_additional resources, so referencing it — even
  # just the "0" key — makes OpenTofu's (resource-grained) dependency graph depend on
  # the whole control_plane_additional resource. That closed a real cycle once
  # node_bootstrap_additional's registration_address started depending on this value:
  # control_plane_additional -> cp_ips -> registration_address ->
  # node_bootstrap_additional -> node_init_additional -> control_plane_additional.
  # genesis_ip reads only control_plane (never _additional), producing the same value
  # without the cycle.
  genesis_ip = local.static_ips ? split("/", var.control_plane_ip_addresses[0])[0] : try(
    [for ip in flatten(proxmox_virtual_environment_vm.control_plane.ipv4_addresses) : ip if !startswith(ip, "127.")][0], null
  )
  registration_address = var.dns_server_address != null ? local.genesis_dns_name : local.genesis_ip

  control_plane_taint = var.cluster_type == "dedicated_control_plane"
  effective_cni       = coalesce(var.cni, "cilium")
  # Cilium operator replica count isn't a per-cluster knob here: kube-image bakes the
  # genesis manifest with a fixed replicas: 1, matching kube-platform's own
  # cilium-app.yaml default (which Argo CD's selfHeal would overwrite anyway) — already
  # the effective end state on every topology.

  # DNS registration (RFC2136): publishes cluster_fqdn -> every resolved control-plane
  # IP, the HA registration/access endpoint (Proxmox has no load-balancer/VIP
  # primitive). Gated on both a domain and a DNS server being supplied — optional per
  # this module's "DNS is optional and name-only" rule.
  dns_registration_enabled = local.has_domain && var.dns_server_address != null
  dns_zone                 = local.has_domain ? "${trimsuffix(var.cluster_domain, ".")}." : null
  dns_record_name          = "api.${var.cluster_name}"

  # Wildcard ingress record: only this module's job on an all_in_one cluster, where
  # the control-plane node is the only place ingress can run. On a
  # dedicated_control_plane cluster the control plane is tainted — proxmox-node-pool
  # publishes the wildcard itself, against its own worker IPs. Registering it here too
  # would point at the wrong nodes and race node-pool's write.
  wildcard_registration_enabled = local.dns_registration_enabled && var.cluster_type == "all_in_one"
  dns_wildcard_record_name      = "*.${var.cluster_name}"

  # dns-registration's provider requires a fully-qualified (trailing-dot) TSIG key
  # name, but DNS servers commonly configure bare names (e.g. Technitium's UI). Qualify
  # here so callers don't need to know this provider quirk. Idempotent either way;
  # coalesced to a placeholder when unused so the (unused) provider block stays valid.
  tsig_key_name_fqdn = "${trimsuffix(coalesce(var.tsig_key_name, "unused"), ".")}."

  # One IP per control-plane node; index 0 is genesis. DHCP works at any
  # control_plane_count — every additional control-plane VM shares the same
  # network_data_dhcp[0] content, resolved individually post-apply via the Proxmox
  # guest agent same as genesis.
  static_ips  = var.control_plane_ip_addresses != null
  cp_ip_cidrs = local.static_ips ? var.control_plane_ip_addresses : []

  _dns_list = join(", ", var.dns_servers)

  # Netplan v2 network-config, one per control-plane index. OpenTofu forbids heredocs
  # inside ternaries, so both branches are precomputed and selected per-index below.
  #
  # "to: 0.0.0.0/0" not Netplan's "to: default": AlmaLinux 9's stock cloud-init doesn't
  # parse "default" in a route's `to:` field — fails init-local with "Address default
  # is not a valid ip address" and silently falls back to NetworkManager's own DHCP
  # profile, no apply-time error. Explicit CIDR is understood by every cloud-init
  # version.
  #
  # "eth0" as the ethernets key directly, not a "primary" alias + match: {name: "en*"}:
  # verified this doesn't work on AlmaLinux 9 — its kernel cmdline sets net.ifnames=0
  # biosdevname=0, so its NIC is always legacy eth0/eth1, never predictable ens*/enp*.
  # Separately, cloud-init's RHEL/NetworkManager renderer ignores `match` entirely,
  # writing the key verbatim as DEVICE= — so a "primary" key produced an unbindable
  # ifcfg-primary that NetworkManager silently left inactive, never erroring, while its
  # own auto-DHCP profile stayed up.
  #
  # NOT independently re-verified against AlmaLinux 10 (the template this module now
  # points at) — both bugs live in cloud-init/NetworkManager internals, not RKE2, so
  # likely unchanged, but that's an assumption. Both workarounds are a superset of
  # stock config's needs — confirm on a real Proxmox apply against AlmaLinux 10 before
  # relying on this in production, and revert to a "match: {name: en*}" primary key if
  # AlmaLinux 10's NIC naming did change.
  network_data_static = { for i, cidr in local.cp_ip_cidrs : i => <<-EOT
    version: 2
    ethernets:
      eth0:
        addresses:
          - ${cidr}
        routes:
          - to: 0.0.0.0/0
            via: ${var.vm_gateway}
        nameservers:
          addresses: [${local._dns_list}]
        dhcp4: false
    EOT
  }
  network_data_dhcp = <<-EOT
    version: 2
    ethernets:
      eth0:
        dhcp4: true
    EOT
}

# ---- Join tokens: generated here, not a shared cluster-facts unit — this is the only
# Proxmox unit that ever needs the server token, and node-pool takes the agent token as
# a plain input wired via Terragrunt, so there's no other unit to share generation
# with. Two tokens, least privilege: the server token grants joining etcd/control-plane;
# the agent token is all a worker ever gets, so a compromised worker can't rejoin as
# control-plane/etcd.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}

resource "proxmox_virtual_environment_firewall_ipset" "cluster" {
  name    = local.cluster_ipset_name
  comment = "kube-compute ${var.cluster_name}: east-west traffic among cluster members (subnet-scoped — see module README)."

  cidr {
    name = coalesce(var.cluster_network_cidr, "${split("/", coalesce(try(var.control_plane_ip_addresses[0], null), "0.0.0.0/32"))[0]}/32")
  }
}

resource "proxmox_virtual_environment_firewall_ipset" "etcd" {
  name    = local.etcd_ipset_name
  comment = "kube-compute ${var.cluster_name}: etcd peer/client traffic, control-plane nodes only."

  dynamic "cidr" {
    for_each = local.cp_ips
    content {
      name = "${cidr.value}/32"
    }
  }
}

resource "proxmox_download_file" "os_image" {
  count = var.os_image_url != null ? 1 : 0

  content_type        = "import"
  datastore_id        = var.iso_datastore_id
  node_name           = var.proxmox_node
  url                 = var.os_image_url
  file_name           = coalesce(var.os_image_file_name, basename(var.os_image_url))
  overwrite_unmanaged = false

  lifecycle {
    precondition {
      condition     = var.os_image_file_name != null || !endswith(var.os_image_url, ".img")
      error_message = "os_image_url ends in '.img' which Proxmox rejects as an import extension. Set os_image_file_name to a .qcow2 filename."
    }
  }
}

resource "proxmox_virtual_environment_file" "vendor_data" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data = join("\n", concat(
      ["#cloud-config", "packages:", "  - qemu-guest-agent"],
      var.ssh_authorized_keys != null ? concat(
        ["ssh_authorized_keys:"],
        [for k in var.ssh_authorized_keys : "  - ${trimspace(k)}"]
      ) : [],
      ["runcmd:", "  - systemctl enable --now qemu-guest-agent", "  - systemctl enable --now serial-getty@ttyS0.service", ""]
    ))
    file_name = "${var.cluster_name}-vendor-data.yaml"
  }
}

module "node_bootstrap" {
  source = "../node-bootstrap"

  cluster_name                    = var.cluster_name
  node_name                       = "${var.cluster_name}-cp-0"
  node_fqdn_label                 = "cp-0"
  cluster_fqdn                    = local.cluster_fqdn
  cluster_fqdn_suffix             = local.fqdn_suffix
  node_role                       = "server-init"
  control_plane_taint             = local.control_plane_taint
  cni                             = local.effective_cni
  cluster_token                   = random_password.server_token.result
  cluster_agent_token             = random_password.agent_token.result
  extra_tls_sans                  = compact([local.wildcard_name, local.genesis_dns_name])
  trusted_ca_pem                  = var.trusted_ca_pem
  registry_mirror_url             = var.registry_mirror_url
  gitops_platform_enabled         = var.gitops_platform_enabled
  gitops_platform_repo_url        = var.gitops_platform_repo_url_override
  gitops_platform_revision        = var.gitops_platform_revision_override
  gitops_workloads_repo_url       = var.gitops_workloads_repo_url
  gitops_workloads_revision       = var.gitops_workloads_revision
  gitops_workloads_path           = var.gitops_workloads_path
  workloads_extra_helm_parameters = var.workloads_extra_helm_parameters
  cert_mode                       = var.cert_mode
  platform_extra_helm_parameters  = var.platform_extra_helm_parameters
  platform_helm_values_object     = var.platform_helm_values_object
  extra_tags                      = var.extra_tags

  genesis_apply_manifests             = var.genesis_apply_manifests
  cluster_autoscaler_crd_wait_enabled = var.cluster_autoscaler_crd_wait_enabled
  extra_server_manifests              = var.extra_server_manifests

  dns_self_register_zone        = var.dns_server_address != null ? local.dns_zone : null
  dns_self_register_record_name = "genesis.${var.cluster_name}"
  dns_self_register_ttl         = var.dns_record_ttl
  dns_server_address            = var.dns_server_address
  dns_server_port               = var.dns_server_port
  dns_transport                 = var.dns_transport
  # Same list this module's own VM network config (network_data_dhcp above)
  # uses — gives kubelet a resolv-conf with no search domain, avoiding a
  # collision between the node's own hostname-derived search domain and a
  # wildcard cluster DNS record (see node-bootstrap's dns_servers variable).
  dns_servers        = var.dns_servers
  tsig_key_name      = var.tsig_key_name
  tsig_key_algorithm = var.tsig_key_algorithm
  tsig_key_secret    = var.tsig_key_secret
}

# node-bootstrap no longer executes anything, so there's no run to order against —
# this is a pure render, plan-time only. Ordering is now enforced by the node itself:
# genesis publishes its dns-self-register record early in first boot, and a sibling
# that resolves registration_address before that lands is absorbed by bootstrap.sh's
# join-race retry loop, same as RKE2's own server/agent join retries.
module "node_bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../node-bootstrap"

  cluster_name        = var.cluster_name
  node_name           = "${var.cluster_name}-cp-${each.key}"
  node_fqdn_label     = "cp-${each.key}"
  cluster_fqdn        = local.cluster_fqdn
  cluster_fqdn_suffix = local.fqdn_suffix
  node_role           = "server-join"
  control_plane_taint = local.control_plane_taint
  cni                 = local.effective_cni
  # local.registration_address: genesis's self-registered DNS name when DNS is
  # configured, its raw IP otherwise — see the no-depends_on comment above for why
  # this doesn't need an explicit Terraform dependency. Always a single target (no
  # round-robin race — see cluster_fqdn's own doc).
  registration_address = local.registration_address
  extra_tls_sans       = compact([local.wildcard_name, local.genesis_dns_name])
  cluster_token        = random_password.server_token.result
  trusted_ca_pem       = var.trusted_ca_pem
  registry_mirror_url  = var.registry_mirror_url
  dns_servers          = var.dns_servers
  cert_mode            = var.cert_mode
  extra_tags           = var.extra_tags
  # gitops_* intentionally omitted: Argo/platform bootstrap runs on the first server only.
}

# Subsumes the old hostname-only snippet — hostname is now one key inside
# node-bootstrap's own cloud-config, alongside the RKE2 config/registries/CA/manifest
# write_files and the bootstrap runcmd, so the two can't drift. vendor_data (SSH keys +
# qemu-guest-agent) and network_data are unrelated to RKE2 and unchanged.
resource "proxmox_virtual_environment_file" "node_init" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  overwrite    = true

  source_raw {
    data      = module.node_bootstrap.cloud_init_user_data
    file_name = "${var.cluster_name}-cp-0-node-init.yaml"
  }
}

resource "proxmox_virtual_environment_file" "node_init_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  overwrite    = true

  source_raw {
    data      = module.node_bootstrap_additional[each.key].cloud_init_user_data
    file_name = "${var.cluster_name}-cp-${each.key}-node-init.yaml"
  }
}

# depends_on the VMs, not node-bootstrap (a pure plan-time render now) — the record
# appears once VMs exist, not once the API server actually answers, since cloud-init
# runs async after Terraform returns and can't be observed finishing. A client that
# resolves too early retries; RKE2's own join paths tolerate an unreachable target.
module "dns_registration" {
  source = "../dns-registration"

  providers  = { dns = dns }
  depends_on = [proxmox_virtual_environment_vm.control_plane, proxmox_virtual_environment_vm.control_plane_additional]

  enabled          = local.dns_registration_enabled
  dns_zone         = coalesce(local.dns_zone, "invalid.")
  record_name      = local.dns_record_name
  record_addresses = values(local.cp_ips)
  record_ttl       = var.dns_record_ttl
}

# Only on all_in_one clusters — see wildcard_registration_enabled above for why a
# dedicated_control_plane cluster leaves this to proxmox-node-pool instead. Same
# depends_on/async reasoning as dns_registration above.
module "dns_registration_wildcard" {
  source = "../dns-registration"

  providers  = { dns = dns }
  depends_on = [proxmox_virtual_environment_vm.control_plane, proxmox_virtual_environment_vm.control_plane_additional]

  enabled          = local.wildcard_registration_enabled
  dns_zone         = coalesce(local.dns_zone, "invalid.")
  record_name      = local.dns_wildcard_record_name
  record_addresses = values(local.cp_ips)
  record_ttl       = var.dns_record_ttl
}

resource "proxmox_virtual_environment_file" "network_data" {
  for_each = local.static_ips ? { for i in range(var.control_plane_count) : tostring(i) => i } : {}

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  overwrite    = true

  source_raw {
    file_name = "${var.cluster_name}-cp-${each.key}-network-data.yaml"
    data      = local.network_data_static[each.value]
  }
}

resource "proxmox_virtual_environment_file" "network_data_dhcp" {
  count = local.static_ips ? 0 : 1

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  overwrite    = true

  source_raw {
    file_name = "${var.cluster_name}-cp-0-network-data.yaml"
    data      = local.network_data_dhcp
  }
}

resource "proxmox_virtual_environment_vm" "control_plane" {
  name            = "${var.cluster_name}-cp-0"
  node_name       = var.proxmox_node
  tags            = ["kube-compute", var.cluster_name, "control-plane"]
  on_boot         = true
  started         = true
  stop_on_destroy = true
  tablet_device   = false
  scsi_hardware   = "virtio-scsi-single"

  agent {
    enabled = true
    timeout = "15m"
    trim    = true
  }

  cpu {
    cores = var.vm_cores
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # full = true is not optional: a linked clone stays dependent on the template
  # surviving, which breaks when kube-image's prune-images.sh deletes an old build.
  dynamic "clone" {
    for_each = var.proxmox_template_vm_id != null ? [var.proxmox_template_vm_id] : []
    content {
      vm_id = clone.value
      full  = true
    }
  }

  disk {
    datastore_id = var.disk_datastore_id
    # Omitted when cloning: the clone already brings its own disk, and size /
    # datastore_id above still override what it inherits.
    import_from = var.proxmox_template_vm_id != null ? null : (var.os_image_url != null ? one(proxmox_download_file.os_image[*].id) : var.os_image_file_id)
    file_id     = null
    interface   = "scsi0"
    size        = var.vm_disk_gb
    discard     = "on"
    iothread    = true
    ssd         = true
  }

  serial_device {}

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
    queues = var.vm_cores
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id         = var.disk_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.node_init.id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = local.static_ips ? proxmox_virtual_environment_file.network_data["0"].id : proxmox_virtual_environment_file.network_data_dhcp[0].id
  }

  lifecycle {
    precondition {
      condition = length(compact([
        var.os_image_url != null ? "url" : "",
        var.os_image_file_id != null ? "file" : "",
        var.proxmox_template_vm_id != null ? "template" : "",
      ])) == 1
      error_message = "Set exactly one of os_image_url (download a stock cloud image), os_image_file_id (a stock image already on Proxmox storage), or proxmox_template_vm_id (full-clone a pre-baked kube-image VM template)."
    }

    precondition {
      condition     = var.control_plane_count == 1 || var.dns_server_address != null
      error_message = "dns_server_address is required when control_plane_count > 1 — multi-node clusters need it to self-register the genesis join address."
    }
  }
}

resource "proxmox_virtual_environment_vm" "control_plane_additional" {
  # Deliberately NOT for_each = module.node_bootstrap_additional. Not a real cycle:
  # node_bootstrap_additional's registration_address resolves through local.genesis_ip,
  # which (per the comment above it) reads only control_plane, never
  # control_plane_additional. (This resource still depends on
  # module.node_bootstrap_additional transitively, via node_init_additional's
  # user_data_file_id below.) for_each is keyed independently simply because this
  # resource's index set is already a pure function of control_plane_count.
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  name            = "${var.cluster_name}-cp-${each.key}"
  node_name       = var.proxmox_node
  tags            = ["kube-compute", var.cluster_name, "control-plane"]
  on_boot         = true
  started         = true
  stop_on_destroy = true
  tablet_device   = false
  scsi_hardware   = "virtio-scsi-single"

  agent {
    enabled = true
    timeout = "15m"
    trim    = true
  }

  cpu {
    cores = var.vm_cores
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # full = true is not optional: a linked clone stays dependent on the template
  # surviving, which breaks when kube-image's prune-images.sh deletes an old build.
  dynamic "clone" {
    for_each = var.proxmox_template_vm_id != null ? [var.proxmox_template_vm_id] : []
    content {
      vm_id = clone.value
      full  = true
    }
  }

  disk {
    datastore_id = var.disk_datastore_id
    # Omitted when cloning: the clone already brings its own disk, and size /
    # datastore_id above still override what it inherits.
    import_from = var.proxmox_template_vm_id != null ? null : (var.os_image_url != null ? one(proxmox_download_file.os_image[*].id) : var.os_image_file_id)
    file_id     = null
    interface   = "scsi0"
    size        = var.vm_disk_gb
    discard     = "on"
    iothread    = true
    ssd         = true
  }

  serial_device {}

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
    queues = var.vm_cores
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id        = var.disk_datastore_id
    user_data_file_id   = proxmox_virtual_environment_file.node_init_additional[each.key].id
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_data.id
    # Same static/DHCP branch as the primary control_plane resource above —
    # network_data_dhcp[0] content is identical for every control-plane node.
    network_data_file_id = local.static_ips ? proxmox_virtual_environment_file.network_data[each.key].id : proxmox_virtual_environment_file.network_data_dhcp[0].id
  }

  depends_on = [proxmox_virtual_environment_vm.control_plane]
}

locals {
  # Resolved IP per control-plane VM, static or via guest agent — same pattern node-proxmox uses.
  cp_ips = merge(
    { "0" = local.genesis_ip },
    {
      for k, vm in proxmox_virtual_environment_vm.control_plane_additional :
      k => local.static_ips ? split("/", var.control_plane_ip_addresses[tonumber(k)])[0] : try(
        [for ip in flatten(vm.ipv4_addresses) : ip if !startswith(ip, "127.")][0], null
      )
    }
  )

  all_cp_vm_ids = merge(
    { "0" = proxmox_virtual_environment_vm.control_plane.vm_id },
    { for k, vm in proxmox_virtual_environment_vm.control_plane_additional : k => vm.vm_id }
  )
}

resource "proxmox_virtual_environment_firewall_options" "control_plane" {
  for_each = local.all_cp_vm_ids

  node_name     = var.proxmox_node
  vm_id         = each.value
  enabled       = true
  dhcp          = !local.static_ips
  input_policy  = "DROP"
  output_policy = "ACCEPT"

  # vm_id isn't ForceNew on this resource, so replacing the underlying VM
  # (e.g. a new proxmox_template_vm_id from a rebuilt image — clone_vm_id IS
  # ForceNew on the VM itself) otherwise leaves this resource in place,
  # pointed at the new vm_id via a plain in-place update. bpg/proxmox's
  # firewall_rules resource then fails ("could not find rule with signature
  # ... during repositioning") because it tries to reposition rules it
  # remembers from the old VM against the new VM's actually-empty ruleset.
  # Forcing replacement whenever the VM replaces keeps this resource's
  # lifecycle tied to the VM it belongs to, avoiding the broken update path
  # entirely. Confirmed against a real apply (image rebuild -> template swap).
  #
  # Deliberately only control_plane, not control_plane_additional: unlike
  # depends_on, replace_triggered_by errors ("no change found for X") if the
  # referenced resource has zero instances — confirmed on a real destroy,
  # which still evaluates this even though it's not applying anything. On a
  # single-control-plane cluster (control_plane_count = 1, this module's
  # common case) control_plane_additional's for_each is always empty, so
  # referencing it here breaks every plan/apply/destroy outright. Known gap:
  # on an HA cluster, replacing only an additional CP node (not the genesis
  # one) won't auto-recreate this shared resource — acceptable for now since
  # the bug this fixes is far more common (any image/template rebuild) than
  # replacing one specific additional CP node in isolation.
  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.control_plane,
    ]
  }
}

resource "proxmox_virtual_environment_firewall_rules" "control_plane" {
  for_each = local.all_cp_vm_ids

  node_name = var.proxmox_node
  vm_id     = each.value

  # See firewall_options.control_plane's identical lifecycle block above for
  # why this is required, and why it's scoped to control_plane only.
  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.control_plane,
    ]
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${local.cluster_ipset_name}"
    comment = "all traffic among cluster members"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "2379:2380"
    source  = "+${local.etcd_ipset_name}"
    comment = "etcd peer/client traffic, control-plane nodes only"
  }

  dynamic "rule" {
    for_each = var.ingress_ports
    content {
      type    = "in"
      action  = "ACCEPT"
      proto   = "tcp"
      dport   = tostring(rule.value)
      source  = var.allowed_ingress_cidrs[0]
      comment = "cluster access port ${rule.value}"
    }
  }
}
