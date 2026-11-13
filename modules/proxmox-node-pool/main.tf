# SPDX-License-Identifier: Apache-2.0
locals {
  # Naming convention only, computed independently from proxmox-control-plane's
  # identical formula (see that module for why there's no shared output). This pool
  # only references the ipset by name; it never creates one.
  cluster_ipset_name = "kube-compute-${var.cluster_name}-cluster"

  static_ips = var.worker_ip_addresses != null
  dns_name   = coalesce(var.cluster_dns_name, var.cluster_name)

  # Wildcard DNS registration (RFC2136): publishes *.<cluster_name> -> every
  # resolved worker IP, for the pool that runs ingress (manage_wildcard_dns_record).
  dns_registration_enabled = var.manage_wildcard_dns_record && var.cluster_domain != null && var.dns_server_address != null
  dns_zone                 = var.cluster_domain != null ? "${trimsuffix(var.cluster_domain, ".")}." : null
  dns_wildcard_record_name = "*.${local.dns_name}"

  # Same formula as proxmox-control-plane's identical local, passed to node-bootstrap
  # so a worker's cloud-init sets a real fqdn, not just hostname. Without it,
  # cc_set_hostname has only a bare hostname (no domain); this distro then prefers a
  # derived fqdn over the literal hostname, and with no domain to derive one from,
  # falls back to reflecting the VM's own template-baked hostname — so every worker
  # cloned from the same template applies that SAME hostname instead of its own
  # node_name. RKE2 registers by hostname, so all workers collided on one hostname;
  # only one could hold the registration, the rest looped forever on "Node password
  # rejected, duplicate hostname".
  fqdn_suffix = var.cluster_domain != null ? "${local.dns_name}.${var.cluster_domain}" : null

  # Proxmox-native delivery: the token is embedded verbatim into this pool's own
  # cloud-init snippet (no secret store to fetch from), unlike AWS's SSM fetch command.
  agent_token_fetch_command = "echo '${var.cluster_agent_token}'"

  # Computed independently — see proxmox-control-plane's identical local for the full
  # reasoning. effective_registration_address below falls back to this when the caller
  # didn't pass var.registration_address explicitly (the no-DNS case). Guards
  # cluster_domain == null so this resolves to null instead of crashing trimsuffix().
  genesis_dns_name = var.cluster_domain != null ? "genesis.${local.dns_name}.${trimsuffix(var.cluster_domain, ".")}" : null

  effective_registration_address = var.registration_address != null ? var.registration_address : (
    var.dns_server_address != null ? local.genesis_dns_name : null
  )

  _dns_list = join(", ", var.dns_servers)
  # "to: 0.0.0.0/0", not Netplan's "to: default", and "eth0" as the ethernets key with
  # no `match` block. See proxmox-control-plane's matching local for the reasons.
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
    file_name = "${var.cluster_name}-${var.pool_name}-vendor-data.yaml"
  }
}

resource "proxmox_virtual_environment_file" "network_data" {
  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  upload_mode  = var.cloud_init_upload_mode
  overwrite    = true

  source_raw {
    file_name = "${var.cluster_name}-${var.pool_name}-${each.key}-network-data.yaml"
    data      = local.network_data_static[each.key]
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  # An index range that is a pure function of desired_count. node_bootstrap reads
  # nothing derived from this VM, so there is no cycle to avoid.
  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  name            = local.worker_names[each.key]
  node_name       = var.proxmox_node
  tags            = distinct(["kube-compute", var.cluster_name, "worker", var.pool_name])
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

  # full = true is not optional: a linked clone stays dependent on the template
  # surviving, which breaks when kube-images' prune-images.sh deletes an old build.
  clone {
    vm_id = var.proxmox_template_vm_id
    full  = true
  }

  cpu {
    cores = var.vm_cores
    type  = var.vm_cpu_type
    units = var.cpu_units
  }

  memory {
    dedicated = var.vm_memory_mb
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
    datastore_id         = var.disk_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.node_init[each.key].id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
  }

  lifecycle {
    # A new template reaches only new or replaced workers, so one apply never
    # rebuilds the whole pool. See the README for the rolling replacement.
    ignore_changes = [clone]

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

# Workers do not wait on each other, because there is no etcd learner race. The RKE2
# agent retries the join URL, so no depends_on on the control plane is needed.
module "boot_steps" {
  source = "../proxmox-boot-steps"

  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  cluster_name    = var.cluster_name
  node_name       = local.worker_names[each.key]
  node_fqdn_label = "${var.pool_name}-${each.key}"
}

module "node_bootstrap" {
  source = "../node-bootstrap"

  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  cluster_name              = var.cluster_name
  node_name                 = local.worker_names[each.key]
  node_fqdn_label           = "${var.pool_name}-${each.key}"
  cluster_fqdn_suffix       = local.fqdn_suffix
  node_role                 = "worker"
  registration_address      = local.effective_registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = merge({ "kube-compute.io/node-group" = var.pool_name }, var.extra_node_labels)
  node_taints               = var.node_taints
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  # Same list this module's own VM network config uses — see node-bootstrap's
  # dns_servers variable for why a worker's kubelet needs this too (every
  # pod scheduled on it inherits the same node-search-domain collision).
  dns_servers = var.dns_servers

  provider_steps    = module.boot_steps[each.key].steps
  provider_files    = module.boot_steps[each.key].files
  graceful_shutdown = var.graceful_shutdown
  os_auto_updates   = var.os_auto_updates
}

# The hostname is a key in node-bootstrap's own cloud-config, so it cannot drift from the
# RKE2 config. vendor_data (SSH keys, guest agent) and network_data are independent of RKE2.
resource "proxmox_virtual_environment_file" "node_init" {
  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  upload_mode  = var.cloud_init_upload_mode
  overwrite    = true

  source_raw {
    data      = module.node_bootstrap[each.key].cloud_init_user_data
    file_name = "${var.cluster_name}-${var.pool_name}-${each.key}-node-init.yaml"
  }
}

# depends_on the VMs, not node-bootstrap (a pure plan-time render) — the record
# appears once VMs exist, not once each worker has joined, since cloud-init runs
# async after apply returns. Clients that resolve early simply retry.
module "dns_registration" {
  source = "../dns-registration"

  depends_on = [proxmox_virtual_environment_vm.worker]

  enabled            = local.dns_registration_enabled
  dns_zone           = coalesce(local.dns_zone, "invalid.")
  record_name        = local.dns_wildcard_record_name
  record_addresses   = values(local.worker_ips)
  record_ttl         = var.dns_record_ttl
  dns_server_address = coalesce(var.dns_server_address, "127.0.0.1")
  dns_server_port    = var.dns_server_port
  dns_transport      = var.dns_transport
  tsig_key_name      = coalesce(var.tsig_key_name, "unused")
  tsig_key_algorithm = var.tsig_key_algorithm
  tsig_key_secret    = coalesce(var.tsig_key_secret, "unused")
}

resource "proxmox_virtual_environment_firewall_options" "worker" {
  for_each = local.worker_vm_ids

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

  # vm_id isn't ForceNew on this resource, so replacing the underlying worker
  # VM (e.g. a new proxmox_template_vm_id from a rebuilt image) otherwise
  # leaves this resource in place, pointed at the new vm_id via a plain
  # in-place update — bpg/proxmox's firewall_rules resource then fails
  # ("could not find rule with signature ... during repositioning") trying to
  # reposition rules it remembers from the old VM against the new VM's
  # actually-empty ruleset. See proxmox-control-plane's similar lifecycle
  # block for the full explanation.
  #
  # The trigger is this worker's own id: the id changes only on replacement,
  # so an in-place update or another worker's replacement leaves it alone.
  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.worker[each.key].id,
    ]
  }
}

resource "proxmox_virtual_environment_firewall_rules" "worker" {
  for_each = local.worker_vm_ids

  node_name = var.proxmox_node
  vm_id     = each.value

  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.worker[each.key].id,
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
