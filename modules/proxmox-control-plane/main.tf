# SPDX-License-Identifier: Apache-2.0
# Configured here (not in dns-registration) because that module needs
# depends_on to sequence its write after node-bootstrap succeeds, and
# Terraform forbids depends_on/count/for_each on a module call whose module
# owns its own provider block — see dns-registration's README. Coalesced to
# harmless placeholders when DNS registration is disabled (var.dns_server_address
# null): this provider is still configured either way since it's passed to an
# always-instantiated module call, but dns-registration's own resource has
# count = 0 in that case, so nothing ever actually dials these placeholders.
provider "dns" {
  update {
    server        = coalesce(var.dns_server_address, "127.0.0.1")
    port          = var.dns_server_port
    transport     = var.dns_transport
    key_name      = local.tsig_key_name_fqdn
    key_algorithm = var.tsig_key_algorithm
    key_secret    = coalesce(var.tsig_key_secret, "dW51c2VkAA==")
  }
}

locals {
  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null

  # The join address for this cluster's own additional-CP joins (module.node_bootstrap_additional
  # below). A single-target DNS name — distinct from cluster_fqdn's round-robin
  # api.* record — genesis self-registers via node-bootstrap's dns_self_register_*
  # inputs (wired below) as soon as it knows its own IP, so this is a plain
  # zero-resource-dependency string whenever DNS is configured; falls back to genesis's
  # raw IP (a real resource dependency, unavoidable without DNS) only when
  # dns_server_address is null.
  genesis_dns_name     = local.has_domain ? "genesis.${var.cluster_name}.${trimsuffix(var.cluster_domain, ".")}" : null
  registration_address = var.dns_server_address != null ? local.genesis_dns_name : local.cp_ips["0"]

  control_plane_taint = var.cluster_type == "dedicated_control_plane"
  effective_cni       = coalesce(var.cni, "cilium")
  # Cilium chart default (2 operator replicas, pod anti-affinity) leaves one
  # replica permanently Pending on a genuinely single-node cluster.
  effective_cilium_operator_replicas = var.control_plane_count > 1 ? null : 1

  # DNS registration (RFC2136): publishes cluster_fqdn -> every resolved control-plane
  # IP, the HA registration/access endpoint (Proxmox has no load-balancer/VIP
  # primitive). Gated on both a domain (cluster_fqdn must exist) and a DNS server
  # being supplied — genuinely optional per this module's "DNS is optional and
  # name-only" rule.
  dns_registration_enabled = local.has_domain && var.dns_server_address != null
  dns_zone                 = local.has_domain ? "${trimsuffix(var.cluster_domain, ".")}." : null
  dns_record_name          = "api.${var.cluster_name}"

  # Wildcard ingress record (*.<cluster_name>.<cluster_domain>): only this
  # module's job on an all_in_one cluster, where the control-plane node is
  # also the only place ingress can run. On a dedicated_control_plane cluster
  # the control plane is tainted — ingress runs on proxmox-node-pool's
  # workers instead, so that module publishes the wildcard record itself,
  # using its own worker IPs. Registering it here too for that case would
  # both be wrong (points at the wrong nodes) and race node-pool's own write.
  wildcard_registration_enabled = local.dns_registration_enabled && var.cluster_type == "all_in_one"
  dns_wildcard_record_name      = "*.${var.cluster_name}"

  # dns-registration's provider requires a fully-qualified (trailing-dot)
  # TSIG key name, but DNS servers commonly configure key names without one
  # (e.g. Technitium's own UI accepts a bare name like "kube-compute") —
  # qualify here so the caller of this module doesn't need to know that
  # provider-specific quirk. Idempotent whether or not var.tsig_key_name
  # already ends in a dot. Only meaningful when dns_registration_enabled;
  # coalesced to a harmless placeholder otherwise so the (unused) provider
  # block below always has a syntactically valid value.
  tsig_key_name_fqdn = "${trimsuffix(coalesce(var.tsig_key_name, "unused"), ".")}."

  # One IP per control-plane node; index 0 is genesis. DHCP (control_plane_ip_addresses left
  # null) works at any control_plane_count — every additional control-plane VM shares the
  # same network_data_dhcp[0] content (see control_plane_additional's initialization block
  # below), resolved individually post-apply via the Proxmox guest agent same as genesis.
  static_ips  = var.control_plane_ip_addresses != null
  cp_ip_cidrs = local.static_ips ? var.control_plane_ip_addresses : []

  _dns_list = join(", ", var.dns_servers)

  # Netplan v2 network-config, one per control-plane index. OpenTofu forbids heredocs inside
  # ternaries, so both branches are precomputed and selected per-index below.
  # "to: 0.0.0.0/0" (not Netplan's own "to: default" shorthand): AlmaLinux 9's
  # stock cloud-init package doesn't parse the "default" keyword in a route's
  # `to:` field (network_state.py's route normalizer expects a real
  # address/CIDR there) — fails the whole init-local stage with "Address
  # default is not a valid ip address", silently falling back to
  # NetworkManager's own DHCP profile instead of ever raising an apply-time
  # error. The explicit CIDR form is understood by every cloud-init version.
  #
  # "eth0" as the ethernets key directly (not a "primary" alias + match:
  # {name: "en*"}): verified this does not work on AlmaLinux 9 — the image's kernel cmdline sets
  # net.ifnames=0 biosdevname=0, so its NIC is always legacy-named eth0/eth1,
  # never systemd-predictable ens*/enp* (the pattern "en*" was written for).
  # Separately, cloud-init's RHEL/NetworkManager renderer doesn't honor
  # `match` at all — it writes the config's key verbatim as DEVICE=, so a
  # "primary" key produced an unbindable ifcfg-primary (DEVICE=primary,
  # no real interface has that name) that NetworkManager silently left
  # inactive, never erroring, while its own auto-DHCP profile stayed up.
  #
  # NOT independently re-verified against AlmaLinux 10 (the template this
  # module now points at) — both bugs live in cloud-init/NetworkManager
  # internals and the GenericCloud kernel cmdline convention, not RKE2, so
  # they're likely unchanged, but that's an assumption. Both workarounds are
  # a superset of what stock config would need (explicit CIDR strictly
  # generalizes "default"; keying "eth0" directly only breaks if AlmaLinux 10
  # switched to predictable ens*/enp* naming) — confirm on a real Proxmox
  # apply against AlmaLinux 10 before relying on this in production, and
  # revert to a "match: {name: en*}" primary key if it turns out AlmaLinux 10
  # NIC naming did change.
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

# ---- Cluster firewall: an ipset scoped to the cluster's L2 subnet CIDR (see plan design note 2) ----
resource "proxmox_virtual_environment_firewall_ipset" "cluster" {
  name    = var.cluster_ipset_name
  comment = "kube-compute ${var.cluster_name}: east-west traffic among cluster members (subnet-scoped — see module README)."

  cidr {
    name = coalesce(var.cluster_network_cidr, "${split("/", coalesce(try(var.control_plane_ip_addresses[0], null), "0.0.0.0/32"))[0]}/32")
  }
}

# ---- etcd firewall: exact control-plane IPs only, never joined by workers ----
resource "proxmox_virtual_environment_firewall_ipset" "etcd" {
  name    = var.etcd_ipset_name
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

# ---- Minimal, RKE2-agnostic boot-time cloud-init: hostname only ----
# SSH-key injection and qemu-guest-agent are already handled by vendor_data
# above, entirely independent of RKE2. inotify sysctls and the hot-plug-CPU
# udev rule moved into node-bootstrap's Ansible role (os-prep tasks). The
# ONLY thing still needed at boot, before Ansible ever connects, is a
# distinct-per-node hostname: RKE2/kubelet defaults the registered
# Kubernetes node name to the OS hostname, so every node MUST get a unique
# one or later nodes silently clobber earlier ones' node registration.
resource "proxmox_virtual_environment_file" "hostname_init" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = "#cloud-config\nhostname: ${var.cluster_name}-cp-0\n"
    file_name = "${var.cluster_name}-cp-0-hostname-init.yaml"
  }
}

resource "proxmox_virtual_environment_file" "hostname_init_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = "#cloud-config\nhostname: ${var.cluster_name}-cp-${each.key}\n"
    file_name = "${var.cluster_name}-cp-${each.key}-hostname-init.yaml"
  }
}

module "node_bootstrap" {
  source = "../node-bootstrap"

  ansible_playbook_path          = var.ansible_playbook_path
  cluster_name                   = var.cluster_name
  node_name                      = "${var.cluster_name}-cp-0"
  k8s_version                    = var.k8s_version
  cluster_fqdn                   = local.cluster_fqdn
  cluster_fqdn_suffix            = local.fqdn_suffix
  node_role                      = "server-init"
  control_plane_taint            = local.control_plane_taint
  cni                            = local.effective_cni
  cilium_operator_replicas       = local.effective_cilium_operator_replicas
  cluster_token                  = var.cluster_token
  cluster_agent_token            = var.cluster_agent_token
  extra_tls_sans                 = compact([local.wildcard_name, local.genesis_dns_name])
  trusted_ca_pem                 = var.trusted_ca_pem
  registry_mirror_url            = var.registry_mirror_url
  gitops_platform_enabled        = var.gitops_platform_enabled
  gitops_platform_repo_url       = var.gitops_platform_repo_url_override
  gitops_platform_revision       = var.gitops_platform_revision_override
  gitops_workloads_repo_url      = var.gitops_workloads_repo_url
  gitops_workloads_revision      = var.gitops_workloads_revision
  gitops_workloads_path          = var.gitops_workloads_path
  cert_mode                      = var.cert_mode
  platform_extra_helm_parameters = var.platform_extra_helm_parameters
  platform_helm_values_object    = var.platform_helm_values_object
  extra_tags                     = var.extra_tags

  dns_self_register_zone        = var.dns_server_address != null ? local.dns_zone : null
  dns_self_register_record_name = "genesis.${var.cluster_name}"
  dns_self_register_ttl         = var.dns_record_ttl
  dns_server_address            = var.dns_server_address
  dns_server_port               = var.dns_server_port
  dns_transport                 = var.dns_transport
  tsig_key_name                 = var.tsig_key_name
  tsig_key_algorithm            = var.tsig_key_algorithm
  tsig_key_secret               = var.tsig_key_secret

  ansible_connection_vars = {
    ansible_connection           = "ssh"
    ansible_host                 = local.cp_ips["0"]
    ansible_user                 = var.ansible_ssh_user
    ansible_ssh_private_key_file = pathexpand(var.ansible_ssh_private_key_file)
    # UserKnownHostsFile=/dev/null makes every connection start from a blank
    # known_hosts, so accept-new always succeeds regardless of what a prior
    # incarnation of this node presented at the same IP — this project's
    # clusters are deliberately disposable (destroy/recreate at a stable
    # static IP is the normal operating model, not an edge case), so a
    # rotated host key on every recreate is expected, not suspicious. Without
    # this, a recreate hits "REMOTE HOST IDENTIFICATION HAS CHANGED" against
    # the operator's real known_hosts and requires a manual `ssh-keygen -R`
    # before every apply after a destroy/recreate. Deliberate trade-off: it
    # still verifies the key isn't swapped mid-apply, but gives up
    # host-key continuity *across* destroy/recreate cycles — acceptable here
    # since the disposable-cluster model already discards that continuity by
    # design once a node is destroyed. Nothing is written to the operator's
    # real ~/.ssh/known_hosts either way. (Same reasoning applies to
    # node_bootstrap_additional's identical block below.)
    ansible_ssh_common_args = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
    # Pinned rather than left to Ansible's auto-discovery: every node this
    # project targets is always AlmaLinux 10 (this project's only supported
    # OS, no compatibility claim for others), so there's nothing to actually
    # discover, and pinning avoids the "future installation of another Python
    # interpreter could cause a different interpreter to be discovered"
    # warning on every run. /usr/bin/python3 is AlmaLinux's own stable
    # symlink to whatever the current default Python actually is (3.12 as of
    # AlmaLinux 10.2) — pin the symlink, not the specific version, so a minor
    # OS bump doesn't silently break this. (Same reasoning applies to
    # node_bootstrap_additional's identical block below.)
    ansible_python_interpreter = "/usr/bin/python3"
  }
}

# Deliberately NOT depends_on module.node_bootstrap — see aws-control-plane's identical
# comment on module.node_bootstrap_additional: that dependency forced every additional
# server's OS-prep/install to wait for genesis's entire Ansible run, including its
# post-Ready GitOps bootstrap, which has nothing to do with etcd join safety. RKE2's
# server process retries its `server:` line the same way its agent process retries a
# worker's join target (see aws-node-pool's established no-depends_on precedent), so a
# sibling starting concurrently with genesis just waits out genesis's install via that
# connection retry. The one genuine ordering requirement — genesis's dns-self-register
# task (node_role == "server-init", gated on dns_self_register_zone) publishing
# genesis_dns_name before a sibling resolves registration_address — self-resolves
# without an explicit dependency: that task runs during genesis's OS-prep, well before
# genesis's own RKE2 install, so it's very likely already published by the time a
# concurrently-bootstrapping sibling reaches its own join attempt; if it isn't yet, the
# sibling's join-race retry loop below (which already tolerates a not-yet-reachable
# target) absorbs the wait via its ordinary wipe-and-retry cycle.
module "node_bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../node-bootstrap"

  ansible_playbook_path    = var.ansible_playbook_path
  cluster_name             = var.cluster_name
  node_name                = "${var.cluster_name}-cp-${each.key}"
  k8s_version              = var.k8s_version
  cluster_fqdn             = local.cluster_fqdn
  cluster_fqdn_suffix      = local.fqdn_suffix
  node_role                = "server-join"
  control_plane_taint      = local.control_plane_taint
  cni                      = local.effective_cni
  cilium_operator_replicas = local.effective_cilium_operator_replicas
  # local.registration_address (genesis's self-registered DNS name when DNS is
  # configured, its raw IP otherwise) — see the no-depends_on comment above
  # module.node_bootstrap_additional for why genesis's dns-self-register task
  # publishing this name before a sibling resolves it doesn't need an explicit
  # Terraform dependency. No round-robin race here (see cluster_fqdn's own doc)
  # — this is always a single target.
  registration_address = local.registration_address
  extra_tls_sans       = compact([local.wildcard_name, local.genesis_dns_name])
  cluster_token        = var.cluster_token
  trusted_ca_pem       = var.trusted_ca_pem
  registry_mirror_url  = var.registry_mirror_url
  cert_mode            = var.cert_mode
  extra_tags           = var.extra_tags
  # gitops_* intentionally omitted: Argo/platform bootstrap runs on the first server only.

  ansible_connection_vars = {
    ansible_connection           = "ssh"
    ansible_host                 = local.cp_ips[each.key]
    ansible_user                 = var.ansible_ssh_user
    ansible_ssh_private_key_file = pathexpand(var.ansible_ssh_private_key_file)
    # Same reasoning as module.node_bootstrap's identical block above.
    ansible_ssh_common_args = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
    # Same reasoning as module.node_bootstrap's identical block above.
    ansible_python_interpreter = "/usr/bin/python3"
  }
}

# ---- DNS registration: publishes cluster_fqdn -> every control-plane IP via RFC2136 ----
# depends_on every node-bootstrap run (not just the VMs) so the record only
# appears once the API server is actually reachable at those IPs — mirrors the
# same "depends on the Ansible run, not just the resource" reasoning used for
# module.node_bootstrap_additional above. Optional: skipped entirely when no
# dns_server_address is supplied (this module creates no DNS by default,
# same as every other provider module in this project).
module "dns_registration" {
  source = "../dns-registration"

  providers  = { dns = dns }
  depends_on = [module.node_bootstrap, module.node_bootstrap_additional]

  enabled          = local.dns_registration_enabled
  dns_zone         = coalesce(local.dns_zone, "invalid.")
  record_name      = local.dns_record_name
  record_addresses = values(local.cp_ips)
  record_ttl       = var.dns_record_ttl
}

# ---- Wildcard DNS registration: publishes *.<cluster_name> -> the same IPs ----
# Only on all_in_one clusters — see wildcard_registration_enabled above for why
# a dedicated_control_plane cluster leaves this to proxmox-node-pool instead.
module "dns_registration_wildcard" {
  source = "../dns-registration"

  providers  = { dns = dns }
  depends_on = [module.node_bootstrap, module.node_bootstrap_additional]

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

  disk {
    datastore_id = var.disk_datastore_id
    import_from  = var.os_image_url != null ? one(proxmox_download_file.os_image[*].id) : var.os_image_file_id
    file_id      = null
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
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id         = var.disk_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.hostname_init.id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = local.static_ips ? proxmox_virtual_environment_file.network_data["0"].id : proxmox_virtual_environment_file.network_data_dhcp[0].id
  }

  lifecycle {
    precondition {
      condition     = (var.os_image_url != null) != (var.os_image_file_id != null)
      error_message = "Set exactly one of os_image_url (download) or os_image_file_id (pre-existing Proxmox file)."
    }

    precondition {
      condition     = var.control_plane_count == 1 || var.dns_server_address != null
      error_message = "dns_server_address is required when control_plane_count > 1 — multi-node clusters need it to self-register the genesis join address."
    }
  }
}

resource "proxmox_virtual_environment_vm" "control_plane_additional" {
  # Deliberately NOT for_each = module.node_bootstrap_additional: that module
  # depends on this VM's own IP (via local.cp_ips), so keying off it here
  # would be circular. Same index range, computed independently.
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

  disk {
    datastore_id = var.disk_datastore_id
    import_from  = var.os_image_url != null ? one(proxmox_download_file.os_image[*].id) : var.os_image_file_id
    file_id      = null
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
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id        = var.disk_datastore_id
    user_data_file_id   = proxmox_virtual_environment_file.hostname_init_additional[each.key].id
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_data.id
    # Same static/DHCP branch as the primary control_plane resource above
    # (network_data is empty when static_ips is false — a DHCP HA cluster has
    # no per-index entries there, just the one shared network_data_dhcp[0]
    # content, identical for every control-plane node).
    network_data_file_id = local.static_ips ? proxmox_virtual_environment_file.network_data[each.key].id : proxmox_virtual_environment_file.network_data_dhcp[0].id
  }

  depends_on = [proxmox_virtual_environment_vm.control_plane]
}

locals {
  # Resolved IP per control-plane VM, static or via guest agent — same pattern node-proxmox uses.
  cp_ips = merge(
    {
      "0" = local.static_ips ? split("/", var.control_plane_ip_addresses[0])[0] : try(
        [for ip in flatten(proxmox_virtual_environment_vm.control_plane.ipv4_addresses) : ip if !startswith(ip, "127.")][0], null
      )
    },
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
}

resource "proxmox_virtual_environment_firewall_rules" "control_plane" {
  for_each = local.all_cp_vm_ids

  node_name = var.proxmox_node
  vm_id     = each.value

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${var.cluster_ipset_name}"
    comment = "all traffic among cluster members"
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    proto   = "tcp"
    dport   = "2379:2380"
    source  = "+${var.etcd_ipset_name}"
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
