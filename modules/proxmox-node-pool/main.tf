# SPDX-License-Identifier: Apache-2.0
locals {
  # Naming convention only, computed independently from proxmox-control-plane's
  # identical formula (see that module for why there's no shared output). This pool
  # only references the ipset by name; it never creates one.
  cluster_ipset_name = "kube-compute-${var.cluster_name}-cluster"

  static_ips = var.worker_ip_addresses != null

  # Wildcard DNS registration (RFC2136): publishes *.<cluster_name> -> every
  # resolved worker IP. See the variable block's comment for why this pool
  # (not proxmox-control-plane) owns the wildcard on a dedicated_control_plane
  # cluster.
  dns_registration_enabled = var.cluster_domain != null && var.dns_server_address != null
  dns_zone                 = var.cluster_domain != null ? "${trimsuffix(var.cluster_domain, ".")}." : null
  dns_wildcard_record_name = "*.${var.cluster_name}"

  # Same formula as proxmox-control-plane's identical local, passed to node-bootstrap
  # so a worker's cloud-init sets a real fqdn, not just hostname. Without it,
  # cc_set_hostname has only a bare hostname (no domain); this distro then prefers a
  # derived fqdn over the literal hostname, and with no domain to derive one from,
  # falls back to reflecting the VM's own template-baked hostname — so every worker
  # cloned from the same template applies that SAME hostname instead of its own
  # node_name. RKE2 registers by hostname, so all workers collided on one hostname;
  # only one could hold the registration, the rest looped forever on "Node password
  # rejected, duplicate hostname" — confirmed on a real 3-worker Proxmox apply.
  fqdn_suffix = var.cluster_domain != null ? "${var.cluster_name}.${var.cluster_domain}" : null

  # Same fully-qualified-TSIG-key-name quirk as proxmox-control-plane — see
  # its identical local for why.
  tsig_key_name_fqdn = "${trimsuffix(coalesce(var.tsig_key_name, "unused"), ".")}."

  # Proxmox-native delivery: the token is embedded verbatim into this pool's own
  # cloud-init snippet (no secret store to fetch from), unlike AWS's SSM fetch command.
  agent_token_fetch_command = "echo '${var.cluster_agent_token}'"

  # Computed independently — see proxmox-control-plane's identical local for the full
  # reasoning. effective_registration_address below falls back to this when the caller
  # didn't pass var.registration_address explicitly (the no-DNS case). Guards
  # cluster_domain == null so this resolves to null instead of crashing trimsuffix().
  genesis_dns_name = var.cluster_domain != null ? "genesis.${var.cluster_name}.${trimsuffix(var.cluster_domain, ".")}" : null

  effective_registration_address = var.registration_address != null ? var.registration_address : (
    var.dns_server_address != null ? local.genesis_dns_name : null
  )

  _dns_list = join(", ", var.dns_servers)
  # "to: 0.0.0.0/0" not Netplan's "to: default": AlmaLinux 9's stock cloud-init doesn't
  # parse "default" in a route's `to:` field — fails init-local and falls back to
  # NetworkManager's DHCP profile instead of the static IP. See proxmox-control-plane's
  # matching local for the full explanation.
  #
  # "eth0" as the ethernets key directly, not a "primary" alias + match: {name: "en*"}:
  # AlmaLinux 9's kernel cmdline sets net.ifnames=0 biosdevname=0, so NICs are always
  # legacy eth0/eth1, never predictable ens*/enp*. cloud-init's RHEL/NetworkManager
  # renderer also ignores `match` entirely, writing the key verbatim as DEVICE= — so
  # "primary" produced an unbindable connection left silently inactive. Not
  # independently re-verified against AlmaLinux 10 (the template this module now
  # targets) — see proxmox-control-plane's matching local.
  network_data_static = { for i in range(var.desired_count) : tostring(i) => local.static_ips ? <<-EOT
    version: 2
    ethernets:
      eth0:
        addresses:
          - ${var.worker_ip_addresses[i]}
        routes:
          - to: 0.0.0.0/0
            via: ${var.vm_gateway}
        nameservers:
          addresses: [${local._dns_list}]
        dhcp4: false
    EOT
    : <<-EOT
    version: 2
    ethernets:
      eth0:
        dhcp4: true
    EOT
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
    file_name = "${var.cluster_name}-worker-vendor-data.yaml"
  }
}

resource "proxmox_virtual_environment_file" "network_data" {
  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  overwrite    = true

  source_raw {
    file_name = "${var.cluster_name}-worker-${each.key}-network-data.yaml"
    data      = local.network_data_static[each.key]
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  # Not for_each = module.node_bootstrap. Post-cutover, node_bootstrap never reads
  # anything derived from this VM — a worker's registration_address/
  # agent_token_fetch_command come from the caller, not its own IP — so there's no
  # cycle to avoid. Kept as an independent index range since it's already a pure
  # function of desired_count.
  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  name            = "${var.cluster_name}-worker-${each.key}"
  node_name       = var.proxmox_node
  tags            = ["kube-compute", var.cluster_name, "worker"]
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

  # full = true is not optional: a linked clone stays dependent on the template
  # surviving, which breaks when kube-image's prune-images.sh deletes an old build.
  dynamic "clone" {
    for_each = var.proxmox_template_vm_id != null ? [var.proxmox_template_vm_id] : []
    content {
      vm_id = clone.value
      full  = true
    }
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
    user_data_file_id    = proxmox_virtual_environment_file.node_init[each.key].id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
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
      condition     = local.effective_registration_address != null
      error_message = "registration_address must be set explicitly when dns_server_address or cluster_domain is null (no DNS configured to self-compute the genesis address from)."
    }
  }
}

locals {
  # Resolved IP per worker VM, static or via guest agent — same pattern proxmox-control-plane uses.
  worker_ips = {
    for k, vm in proxmox_virtual_environment_vm.worker :
    k => local.static_ips ? split("/", var.worker_ip_addresses[tonumber(k)])[0] : try(
      [for ip in flatten(vm.ipv4_addresses) : ip if !startswith(ip, "127.")][0], null
    )
  }

  # Projected down to vm_id only, same pattern proxmox-control-plane's all_cp_vm_ids
  # uses: for_each-ing the full proxmox_virtual_environment_vm object carries every
  # attribute (including deprecated ones like timeout_move_disk) into the consuming
  # resource, which is what surfaces the provider's "derived from a deprecated
  # source" warning even though only vm_id is ever used below.
  worker_vm_ids = { for k, vm in proxmox_virtual_environment_vm.worker : k => vm.vm_id }
}

# Workers don't need to wait on each other like server-join siblings do (no etcd
# learner race — each fetches its own agent token and joins independently). RKE2's
# agent process retries against the join URL, so no explicit depends_on on the
# control plane's bootstrap is added either; the consumer's root module creates the
# natural data dependency via var.registration_address.
module "node_bootstrap" {
  source = "../node-bootstrap"

  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-worker-${each.key}"
  node_fqdn_label           = "worker-${each.key}"
  cluster_fqdn_suffix       = local.fqdn_suffix
  node_role                 = "worker"
  registration_address      = local.effective_registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = var.extra_node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  # Same list this module's own VM network config uses — see node-bootstrap's
  # dns_servers variable for why a worker's kubelet needs this too (every
  # pod scheduled on it inherits the same node-search-domain collision).
  dns_servers = var.dns_servers

  iscsi_initiator_enabled = true
}

# Subsumes the old hostname-only snippet — hostname is now one key inside
# node-bootstrap's own cloud-config, alongside the RKE2 config, registry mirror
# config, trusted CA, and the bootstrap runcmd. vendor_data (SSH keys +
# qemu-guest-agent) and network_data are unrelated to RKE2 and unchanged.
resource "proxmox_virtual_environment_file" "node_init" {
  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  overwrite    = true

  source_raw {
    data      = module.node_bootstrap[each.key].cloud_init_user_data
    file_name = "${var.cluster_name}-worker-${each.key}-node-init.yaml"
  }
}

# depends_on the VMs, not node-bootstrap (a pure plan-time render) — the record
# appears once VMs exist, not once each worker has joined, since cloud-init runs
# async after apply returns. Clients that resolve early simply retry.
module "dns_registration" {
  source = "../dns-registration"

  providers  = { dns = dns }
  depends_on = [proxmox_virtual_environment_vm.worker]

  enabled          = local.dns_registration_enabled
  dns_zone         = coalesce(local.dns_zone, "invalid.")
  record_name      = local.dns_wildcard_record_name
  record_addresses = values(local.worker_ips)
  record_ttl       = var.dns_record_ttl
}

resource "proxmox_virtual_environment_firewall_options" "worker" {
  for_each = local.worker_vm_ids

  node_name     = var.proxmox_node
  vm_id         = each.value
  enabled       = true
  dhcp          = !local.static_ips
  input_policy  = "DROP"
  output_policy = "ACCEPT"

  # vm_id isn't ForceNew on this resource, so replacing the underlying worker
  # VM (e.g. a new proxmox_template_vm_id from a rebuilt image) otherwise
  # leaves this resource in place, pointed at the new vm_id via a plain
  # in-place update — bpg/proxmox's firewall_rules resource then fails
  # ("could not find rule with signature ... during repositioning") trying to
  # reposition rules it remembers from the old VM against the new VM's
  # actually-empty ruleset. See proxmox-control-plane's identical lifecycle
  # block for the full explanation; confirmed against a real apply.
  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.worker,
    ]
  }
}

resource "proxmox_virtual_environment_firewall_rules" "worker" {
  for_each = local.worker_vm_ids

  node_name = var.proxmox_node
  vm_id     = each.value

  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.worker,
    ]
  }

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${local.cluster_ipset_name}"
    comment = "all traffic among cluster members"
  }
}
