# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  # Falls back to the platform-wide default when the caller doesn't override k8s_version.
  k8s_version = coalesce(var.k8s_version, module.component_versions.k8s_version)

  static_ips = var.worker_ip_addresses != null

  # Proxmox-native delivery: the token is embedded verbatim into this pool's own
  # cloud-init snippet (no secret store to fetch from), unlike AWS's SSM fetch command.
  agent_token_fetch_command = "echo '${var.cluster_agent_token}'"

  version_regex               = "^v(\\d+)\\.(\\d+)\\.(\\d+)\\+"
  pool_version_parts          = regex(local.version_regex, local.k8s_version)
  control_plane_version_parts = regex(local.version_regex, var.control_plane_k8s_version)
  pool_version_num            = tonumber(local.pool_version_parts[0]) * 1000000 + tonumber(local.pool_version_parts[1]) * 1000 + tonumber(local.pool_version_parts[2])
  control_plane_version_num   = tonumber(local.control_plane_version_parts[0]) * 1000000 + tonumber(local.control_plane_version_parts[1]) * 1000 + tonumber(local.control_plane_version_parts[2])

  _dns_list = join(", ", var.dns_servers)
  # "to: 0.0.0.0/0" (not Netplan's own "to: default" shorthand): AlmaLinux 9's
  # stock cloud-init package doesn't parse the "default" keyword in a route's
  # `to:` field — fails the whole init-local stage and silently falls back to
  # NetworkManager's own DHCP profile instead of the static IP. See
  # proxmox-control-plane's matching local for the full explanation.
  #
  # "eth0" as the ethernets key directly (not a "primary" alias + match:
  # {name: "en*"}): AlmaLinux 9's kernel cmdline sets net.ifnames=0
  # biosdevname=0, so its NIC is always legacy-named eth0/eth1, never
  # systemd-predictable ens*/enp*. Separately, cloud-init's RHEL/
  # NetworkManager renderer doesn't honor `match` at all — it writes the
  # config's key verbatim as DEVICE=, so "primary" produced an unbindable
  # connection NetworkManager silently left inactive. See
  # proxmox-control-plane's matching local for the full explanation, including
  # the caveat that this hasn't been independently re-verified against
  # AlmaLinux 10 (the template this module now points at).
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

# ---- Minimal, RKE2-agnostic boot-time cloud-init: hostname only ----
# SSH-key injection and qemu-guest-agent are already handled by vendor_data
# above. inotify sysctls and the hot-plug-CPU udev rule moved into
# node-bootstrap's Ansible role (os-prep tasks). The only thing still needed
# at boot, before Ansible ever connects, is a distinct-per-node hostname —
# see proxmox-control-plane's identical resource for the full reasoning.
resource "proxmox_virtual_environment_file" "hostname_init" {
  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = "#cloud-config\nhostname: ${var.cluster_name}-worker-${each.key}\n"
    file_name = "${var.cluster_name}-worker-${each.key}-hostname-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  # Deliberately an independent index range, not for_each = module.node_bootstrap:
  # that module depends on this VM's own IP (via local.worker_ips), so keying off
  # it here would be circular — see proxmox-control-plane's identical comment.
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
    user_data_file_id    = proxmox_virtual_environment_file.hostname_init[each.key].id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
  }

  lifecycle {
    precondition {
      condition     = (var.os_image_url != null) != (var.os_image_file_id != null)
      error_message = "Set exactly one of os_image_url (download) or os_image_file_id (pre-existing Proxmox file)."
    }
    precondition {
      condition     = local.pool_version_num <= local.control_plane_version_num
      error_message = "k8s_version (${local.k8s_version}) must not be newer than the control plane's k8s_version (${var.control_plane_k8s_version})."
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
}

# Workers don't need to wait on each other the way server-join siblings do
# (no etcd learner race — each worker independently fetches its own agent
# token and joins). RKE2's agent process natively retries against the join
# URL if the control plane isn't reachable yet, so no explicit depends_on
# on the control-plane's own bootstrap is added here either; the consumer's
# root module still creates the natural data dependency via
# var.registration_address.
module "node_bootstrap" {
  source = "../node-bootstrap"

  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  ansible_playbook_path     = var.ansible_playbook_path
  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-worker-${each.key}"
  k8s_version               = local.k8s_version
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = var.extra_node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url

  ansible_connection_vars = {
    ansible_connection           = "ssh"
    ansible_host                 = local.worker_ips[each.key]
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
    # before every apply — confirmed hitting this repeatedly against a real
    # cluster-1 destroy/recreate cycle. Deliberate trade-off, confirmed with
    # the user: still verifies the key isn't swapped mid-apply, but gives up
    # host-key continuity *across* destroy/recreate cycles — acceptable here
    # since the disposable-cluster model already discards that continuity by
    # design once a node is destroyed. Nothing is written to the operator's
    # real ~/.ssh/known_hosts either way.
    ansible_ssh_common_args = "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null"
    # Pinned rather than left to Ansible's auto-discovery: every node this
    # project targets is always AlmaLinux 10 (this project's only supported
    # OS, no compatibility claim for others), so there's nothing to actually
    # discover, and pinning avoids the "future installation of another Python
    # interpreter could cause a different interpreter to be discovered"
    # warning on every run. /usr/bin/python3 is AlmaLinux's own stable
    # symlink to whatever the current default Python actually is (3.12 as of
    # AlmaLinux 10.2) — pin the symlink, not the specific version, so a minor
    # OS bump doesn't silently break this.
    ansible_python_interpreter = "/usr/bin/python3"
  }
}

resource "proxmox_virtual_environment_firewall_options" "worker" {
  for_each = proxmox_virtual_environment_vm.worker

  node_name     = var.proxmox_node
  vm_id         = each.value.vm_id
  enabled       = true
  dhcp          = !local.static_ips
  input_policy  = "DROP"
  output_policy = "ACCEPT"
}

resource "proxmox_virtual_environment_firewall_rules" "worker" {
  for_each = proxmox_virtual_environment_vm.worker

  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  rule {
    type    = "in"
    action  = "ACCEPT"
    source  = "+${var.cluster_ipset_name}"
    comment = "all traffic among cluster members"
  }
}
