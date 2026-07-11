# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../cloud-init/templates/cloud-init-ubuntu-2604.yaml.tpl")

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
  network_data_static = { for i in range(var.desired_count) : tostring(i) => local.static_ips ? <<-EOT
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        addresses:
          - ${var.worker_ip_addresses[i]}
        routes:
          - to: default
            via: ${var.vm_gateway}
        nameservers:
          addresses: [${local._dns_list}]
        dhcp4: false
    EOT
    : <<-EOT
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
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

module "bootstrap" {
  source = "../cloud-init"

  for_each = { for i in range(var.desired_count) : tostring(i) => i }

  cloud_init_template       = local.cloud_init_template
  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-worker-${each.key}"
  k8s_version               = local.k8s_version
  node_role                 = "worker"
  registration_address      = var.registration_address
  agent_token_fetch_command = local.agent_token_fetch_command
  node_labels               = var.extra_node_labels
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
}

resource "proxmox_virtual_environment_file" "cloud_init" {
  for_each = module.bootstrap

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = each.value.cloud_init
    file_name = "${var.cluster_name}-worker-${each.key}-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "worker" {
  for_each = module.bootstrap

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
    user_data_file_id    = proxmox_virtual_environment_file.cloud_init[each.key].id
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
