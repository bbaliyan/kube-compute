# SPDX-License-Identifier: Apache-2.0
locals {
  # Naming convention only — node-pool computes the identical formula from its own
  # cluster_name to reference this module's ipset by name, with no Terraform
  # dependency between the two modules. This module owns the ipset resources;
  # node-pool never creates one.
  cluster_ipset_name = "kube-compute-${var.cluster_name}-cluster"

  has_domain    = var.cluster_domain != null
  dns_name      = coalesce(var.cluster_dns_name, var.cluster_name)
  fqdn_suffix   = local.has_domain ? "${local.dns_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null

  # Join address of every node but genesis. A single-target DNS name, distinct from
  # cluster_fqdn's round-robin api.* record. Genesis self-registers it through
  # node-bootstrap's dns_self_register_* inputs as soon as it knows its own IP. The
  # precondition on the VMs requires dns_server_address when control_plane_count > 1,
  # so this is a plain string with no dependency on any VM.
  genesis_dns_name     = local.has_domain ? "genesis.${local.dns_name}.${trimsuffix(var.cluster_domain, ".")}" : null
  registration_address = local.genesis_dns_name

  # A replaced genesis node must probe its peers, not registration_address: that address
  # resolves to genesis itself, and genesis rewrites the genesis DNS record to itself before the
  # probe runs, so the probe would never see the live cluster. With static IPs it probes every
  # other control-plane node, so one peer being down does not hide the live cluster. With DHCP
  # no peer IP is known before genesis exists (a DHCP peer IP would close a dependency cycle),
  # so it probes cluster_fqdn when DNS registration publishes it: the node resolves the name
  # and skips its own IP. This is the same probe the AWS modules make of their registration
  # address.
  genesis_rejoin_probe_addresses = (
    var.control_plane_count == 1 ? [] :
    local.static_ips ? [for cidr in slice(var.control_plane_ip_addresses, 1, var.control_plane_count) : split("/", cidr)[0]] :
    local.dns_registration_enabled ? [local.cluster_fqdn] : []
  )

  control_plane_taint = var.cluster_type == "dedicated_control_plane"
  effective_cni       = coalesce(var.cni, "cilium")
  # Cilium operator replica count isn't a per-cluster knob here: kube-images bakes the
  # genesis manifest with a fixed replicas: 1, matching kube-platform's own
  # cilium-app.yaml default (which Argo CD's selfHeal would overwrite anyway) — already
  # the effective end state on every topology.

  # DNS registration (RFC2136): publishes cluster_fqdn -> every resolved control-plane
  # IP, the HA registration/access endpoint (Proxmox has no load-balancer/VIP
  # primitive). Gated on both a domain and a DNS server being supplied — optional per
  # this module's "DNS is optional and name-only" rule.
  dns_registration_enabled = local.has_domain && var.dns_server_address != null
  dns_zone                 = local.has_domain ? "${trimsuffix(var.cluster_domain, ".")}." : null
  dns_record_name          = "api.${local.dns_name}"

  # Wildcard ingress record: only this module's job on an all_in_one cluster, where
  # the control-plane node is the only place ingress can run. On a
  # dedicated_control_plane cluster the control plane is tainted — proxmox-node-pool
  # publishes the wildcard itself, against its own worker IPs. Registering it here too
  # would point at the wrong nodes and race node-pool's write.
  wildcard_registration_enabled = var.manage_wildcard_dns_record && local.dns_registration_enabled && var.cluster_type == "all_in_one"
  dns_wildcard_record_name      = "*.${local.dns_name}"

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
  # "to: 0.0.0.0/0", not Netplan's "to: default": some cloud-init versions do not parse
  # "default" in a route's `to:` field. They fall back to NetworkManager's DHCP profile
  # with no apply-time error. An explicit CIDR works on every version.
  #
  # "eth0" is the ethernets key itself, not a "primary" alias with a `match` block:
  # cloud-init's NetworkManager renderer ignores `match` and writes the key verbatim as
  # DEVICE=, which leaves an unbindable connection inactive. The guest NIC is named eth0.
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

module "vendor_data" {
  source = "../proxmox-vendor-data"

  ssh_authorized_keys = var.ssh_authorized_keys
}

resource "proxmox_virtual_environment_file" "vendor_data" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  upload_mode  = var.cloud_init_upload_mode

  source_raw {
    data      = module.vendor_data.data
    file_name = "${var.cluster_name}-vendor-data.yaml"
  }
}

# Key "0" is genesis (server-init); every other key joins it (server-join). The
# GitOps, manifest and DNS self-registration inputs reach genesis only. A joining
# node gets each input's node-bootstrap default, so its render is the same as when
# it had a module call of its own.
#
# node-bootstrap is a pure plan-time render, so there is no run to order against.
# The node orders itself: genesis publishes its dns-self-register record early in
# first boot, and a sibling that resolves registration_address before that lands is
# absorbed by bootstrap.sh's join-race retry loop, like RKE2's own join retries.
module "node_bootstrap" {
  for_each = { for i in range(var.control_plane_count) : tostring(i) => i }

  source = "../node-bootstrap"

  cluster_name                    = var.cluster_name
  node_name                       = local.control_plane_names[each.key]
  node_fqdn_label                 = "cp-${each.key}"
  cluster_fqdn                    = local.cluster_fqdn
  cluster_fqdn_suffix             = local.fqdn_suffix
  node_role                       = each.key == "0" ? "server-init" : "server-join"
  control_plane_taint             = local.control_plane_taint
  cni                             = local.effective_cni
  cluster_token                   = random_password.server_token.result
  cluster_agent_token             = each.key == "0" ? random_password.agent_token.result : null
  registration_address            = each.key == "0" ? null : local.registration_address
  rejoin_probe_addresses          = each.key == "0" ? local.genesis_rejoin_probe_addresses : []
  extra_tls_sans                  = compact([local.wildcard_name, local.genesis_dns_name])
  trusted_ca_pem                  = var.trusted_ca_pem
  registry_mirror_url             = var.registry_mirror_url
  gitops_platform_enabled         = each.key == "0" ? var.gitops_platform_enabled : true
  gitops_platform_repo_url        = each.key == "0" ? var.gitops_platform_repo_url_override : null
  gitops_platform_revision        = each.key == "0" ? var.gitops_platform_revision_override : null
  argocd_manifest_url             = each.key == "0" ? var.argocd_manifest_url : null
  argocd_manifest_sha256          = each.key == "0" ? var.argocd_manifest_sha256 : null
  gitops_workloads_repo_url       = each.key == "0" ? var.gitops_workloads_repo_url : null
  gitops_workloads_revision       = each.key == "0" ? var.gitops_workloads_revision : "main"
  gitops_workloads_path           = each.key == "0" ? var.gitops_workloads_path : "."
  workloads_extra_helm_parameters = each.key == "0" ? var.workloads_extra_helm_parameters : {}
  workloads_helm_values_object    = each.key == "0" ? var.workloads_helm_values_object : null
  cert_mode                       = var.cert_mode
  platform_extra_helm_parameters  = each.key == "0" ? var.platform_extra_helm_parameters : {}
  platform_helm_values_object     = each.key == "0" ? var.platform_helm_values_object : null
  extra_tags                      = var.extra_tags
  iscsi_initiator_enabled         = true
  boot_scripts                    = var.boot_scripts

  genesis_apply_manifests = each.key == "0" ? var.genesis_apply_manifests : []
  extra_server_manifests  = each.key == "0" ? var.extra_server_manifests : {}

  dns_self_register_zone        = each.key == "0" && var.dns_server_address != null ? local.dns_zone : null
  dns_self_register_record_name = each.key == "0" ? "genesis.${local.dns_name}" : null
  dns_self_register_ttl         = each.key == "0" ? var.dns_record_ttl : 30
  dns_server_address            = each.key == "0" ? var.dns_server_address : null
  dns_server_port               = each.key == "0" ? var.dns_server_port : 53
  dns_transport                 = each.key == "0" ? var.dns_transport : "udp"
  # Same list this module's own VM network config (network_data_dhcp above)
  # uses — gives kubelet a resolv-conf with no search domain, avoiding a
  # collision between the node's own hostname-derived search domain and a
  # wildcard cluster DNS record (see node-bootstrap's dns_servers variable).
  dns_servers        = var.dns_servers
  tsig_key_name      = each.key == "0" ? var.tsig_key_name : null
  tsig_key_algorithm = each.key == "0" ? var.tsig_key_algorithm : "hmac-sha256"
  tsig_key_secret    = each.key == "0" ? var.tsig_key_secret : null
  graceful_shutdown  = var.graceful_shutdown
  os_auto_updates    = var.os_auto_updates
}

# Subsumes the old hostname-only snippet — hostname is now one key inside
# node-bootstrap's own cloud-config, alongside the RKE2 config/registries/CA/manifest
# write_files and the bootstrap runcmd, so the two can't drift. vendor_data (SSH keys +
# qemu-guest-agent) and network_data are unrelated to RKE2 and unchanged.
resource "proxmox_virtual_environment_file" "node_init" {
  for_each = { for i in range(var.control_plane_count) : tostring(i) => i }

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  upload_mode  = var.cloud_init_upload_mode
  overwrite    = true

  source_raw {
    data      = module.node_bootstrap[each.key].user_data
    file_name = "${var.cluster_name}-cp-${each.key}-node-init.yaml"
  }
}

# depends_on the VMs, not node-bootstrap (a pure plan-time render now) — the record
# appears once VMs exist, not once the API server actually answers, since cloud-init
# runs async after Terraform returns and can't be observed finishing. A client that
# resolves too early retries; RKE2's own join paths tolerate an unreachable target.
module "dns_registration" {
  source = "../dns-registration"

  depends_on = [proxmox_virtual_environment_vm.control_plane]

  enabled            = local.dns_registration_enabled
  dns_zone           = coalesce(local.dns_zone, "invalid.")
  record_name        = local.dns_record_name
  record_addresses   = values(local.cp_ips)
  record_ttl         = var.dns_record_ttl
  dns_server_address = coalesce(var.dns_server_address, "127.0.0.1")
  dns_server_port    = var.dns_server_port
  dns_transport      = var.dns_transport
  tsig_key_name      = coalesce(var.tsig_key_name, "unused")
  tsig_key_algorithm = var.tsig_key_algorithm
  tsig_key_secret    = coalesce(var.tsig_key_secret, "unused")
}

# Only on all_in_one clusters — see wildcard_registration_enabled above for why a
# dedicated_control_plane cluster leaves this to proxmox-node-pool instead. Same
# depends_on/async reasoning as dns_registration above.
module "dns_registration_wildcard" {
  source = "../dns-registration"

  depends_on = [proxmox_virtual_environment_vm.control_plane]

  enabled            = local.wildcard_registration_enabled
  dns_zone           = coalesce(local.dns_zone, "invalid.")
  record_name        = local.dns_wildcard_record_name
  record_addresses   = values(local.cp_ips)
  record_ttl         = var.dns_record_ttl
  dns_server_address = coalesce(var.dns_server_address, "127.0.0.1")
  dns_server_port    = var.dns_server_port
  dns_transport      = var.dns_transport
  tsig_key_name      = coalesce(var.tsig_key_name, "unused")
  tsig_key_algorithm = var.tsig_key_algorithm
  tsig_key_secret    = coalesce(var.tsig_key_secret, "unused")
}

resource "proxmox_virtual_environment_file" "network_data" {
  for_each = local.static_ips ? { for i in range(var.control_plane_count) : tostring(i) => i } : {}

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  upload_mode  = var.cloud_init_upload_mode
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
  upload_mode  = var.cloud_init_upload_mode
  overwrite    = true

  source_raw {
    file_name = "${var.cluster_name}-cp-0-network-data.yaml"
    data      = local.network_data_dhcp
  }
}

# One VM per control-plane node; key "0" is genesis. The other nodes no longer wait
# for genesis to be created: a resource cannot depend on its own instances. They
# join through genesis's DNS record and retry until it answers, as above.
resource "proxmox_virtual_environment_vm" "control_plane" {
  for_each = { for i in range(var.control_plane_count) : tostring(i) => i }

  name            = local.control_plane_names[each.key]
  node_name       = var.proxmox_node
  tags            = ["kube-compute", var.cluster_name, "control-plane"]
  on_boot         = true
  started         = true
  stop_on_destroy = true
  pool_id         = var.pool_id
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
    units = var.cpu_units
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # full = true is not optional: a linked clone stays dependent on the template
  # surviving, which breaks when kube-images' prune-images.sh deletes an old build.
  clone {
    vm_id = var.proxmox_template_vm_id
    full  = true
  }

  disk {
    datastore_id = var.disk_datastore_id
    interface    = "scsi0"
    size         = var.vm_disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  serial_device {}

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
    queues = var.vm_cores
    # Proxmox only enforces this VM's firewall rules (below) on a NIC that
    # opts in, and only with the datacenter firewall on (see the README).
    firewall = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id        = var.disk_datastore_id
    user_data_file_id   = proxmox_virtual_environment_file.node_init[each.key].id
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_data.id
    # network_data_dhcp[0] content is identical for every control-plane node.
    network_data_file_id = local.static_ips ? proxmox_virtual_environment_file.network_data[each.key].id : proxmox_virtual_environment_file.network_data_dhcp[0].id
  }

  lifecycle {
    # A new template reaches only new or replaced VMs, so one apply never
    # rebuilds every control-plane node and etcd member. See the README for
    # the rolling replacement.
    ignore_changes = [clone]

    precondition {
      condition     = var.control_plane_count == 1 || var.dns_server_address != null
      error_message = "dns_server_address is required when control_plane_count > 1 — multi-node clusters need it to self-register the genesis join address."
    }
  }
}

locals {
  # Resolved IP per control-plane VM, static or via guest agent — same pattern node-proxmox uses.
  cp_ips = {
    for k, vm in proxmox_virtual_environment_vm.control_plane :
    k => local.static_ips ? split("/", var.control_plane_ip_addresses[tonumber(k)])[0] : try(
      [for ip in flatten(vm.ipv4_addresses) : ip if !startswith(ip, "127.")][0], null
    )
  }

  all_cp_vm_ids = { for k, vm in proxmox_virtual_environment_vm.control_plane : k => vm.vm_id }
}

resource "proxmox_virtual_environment_firewall_options" "control_plane" {
  for_each = local.all_cp_vm_ids

  node_name = var.proxmox_node
  vm_id     = each.value
  enabled   = true
  dhcp      = !local.static_ips
  # IPv6 neighbour discovery and router advertisements, which Proxmox allows
  # by default but bpg turns off unless set: without them the VMs lose IPv6
  # routing once the firewall is enforced.
  ndp           = true
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
  # entirely.
  #
  # The trigger is this node's own VM id: the id changes only on replacement,
  # so an in-place update or another node's replacement leaves it alone.
  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.control_plane[each.key].id,
    ]
  }
}

resource "proxmox_virtual_environment_firewall_rules" "control_plane" {
  for_each = local.all_cp_vm_ids

  node_name = var.proxmox_node
  vm_id     = each.value

  # See firewall_options.control_plane's identical lifecycle block above.
  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.control_plane[each.key].id,
    ]
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${local.cluster_ipset_name}"
    comment = "all traffic among cluster members"
  }

  dynamic "rule" {
    for_each = setproduct(var.allowed_ingress_cidrs, var.ingress_ports)
    content {
      type    = "in"
      action  = "ACCEPT"
      proto   = "tcp"
      dport   = tostring(rule.value[1])
      source  = rule.value[0]
      comment = "cluster access port ${rule.value[1]}"
    }
  }
}
