# SPDX-License-Identifier: Apache-2.0

locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../node-bootstrap/templates/cloud-init-ubuntu-2604.yaml.tpl")

  # DNS naming — no records are ever created; Proxmox has no managed DNS.
  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null

  # Static IP is known at plan time. DHCP IP comes from the guest agent after boot.
  static_ip  = var.vm_ip_address != null
  cluster_ip = local.static_ip ? split("/", var.vm_ip_address)[0] : try(
    [for ip in flatten(proxmox_virtual_environment_vm.node.ipv4_addresses) : ip if !startswith(ip, "127.")][0],
    null
  )

}

module "bootstrap" {
  source = "../node-bootstrap"

  cloud_init_template       = local.cloud_init_template
  cluster_name              = var.cluster_name
  k8s_version               = var.k8s_version
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  gitops_platform_repo_url  = var.gitops_platform_repo_url
  gitops_platform_revision  = var.gitops_platform_revision
  gitops_workloads_repo_url = var.gitops_workloads_repo_url
  gitops_workloads_revision = var.gitops_workloads_revision
  gitops_workloads_path     = var.gitops_workloads_path
  cluster_fqdn              = local.cluster_fqdn
}

# Download OS image to Proxmox storage as import content type. Skipped when os_image_file_id is provided.
# Uses content_type="import" (PVE 9 import API path) to avoid the ipcc_send_rec ACL-load failure
# that occurs with content_type="iso" + file_id for non-root PAM tokens.
# The filename is derived from the URL so multiple clusters sharing the same URL reuse one download.
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
      error_message = "os_image_url ends in '.img' which Proxmox rejects as an import extension. Set os_image_file_name to a .qcow2 filename (e.g. 'ubuntu-26.04-server-cloudimg-amd64.qcow2')."
    }
  }
}

# Network-config snippet: uses match-by-name instead of the hard-coded "eth0" that
# Proxmox generates via ip_config. Ubuntu 26.04 uses predictable interface names
# (ens18, eno1, etc.). The auto-generated config tries to rename the interface to "eth0"
# at cloud-init time but fails (interface already up/busy), so the static IP is never
# applied and the VM falls back to DHCP. Providing our own network-config avoids this.
resource "proxmox_virtual_environment_file" "network_data" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node
  overwrite    = true

  source_raw {
    file_name = "${var.cluster_name}-network-data.yaml"
    data      = var.vm_ip_address != null ? <<-EOT
      version: 2
      ethernets:
        primary:
          match:
            name: "en*"
          addresses:
            - ${var.vm_ip_address}
          routes:
            - to: default
              via: ${var.vm_gateway}
          nameservers:
            addresses: [1.1.1.1, 8.8.8.8]
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

# Cloud-init user-data from node-bootstrap, uploaded as a Proxmox snippet.
resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = module.bootstrap.cloud_init
    file_name = "${var.cluster_name}-cloud-init.yaml"
  }
}

# Vendor-data: install and enable qemu-guest-agent on first boot.
# Required for out-of-band access via `qm guest exec` (kube-status / kube-kubeconfig).
# Kept here — not in node-bootstrap — because qemu-guest-agent is a Proxmox runtime detail.
resource "proxmox_virtual_environment_file" "vendor_data" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data = join("\n", concat(
      [
        "#cloud-config",
        "packages:",
        "  - qemu-guest-agent",
      ],
      var.ssh_authorized_keys != null ? concat(
        ["ssh_authorized_keys:"],
        [for k in var.ssh_authorized_keys : "  - ${trimspace(k)}"]
      ) : [],
      [
        "runcmd:",
        "  - systemctl enable --now qemu-guest-agent",
        "  - systemctl enable --now serial-getty@ttyS0.service",
        "",
      ]
    ))
    file_name = "${var.cluster_name}-vendor-data.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  name            = var.cluster_name
  node_name       = var.proxmox_node
  vm_id           = var.vm_id
  tags            = ["kube-node", var.cluster_name]
  on_boot         = true
  started         = true
  stop_on_destroy = true
  tablet_device   = false        # no USB cursor device needed for a headless server
  scsi_hardware   = "virtio-scsi-single" # one controller+queue per disk; pairs with iothread=true

  lifecycle {
    precondition {
      condition     = (var.os_image_url != null) != (var.os_image_file_id != null)
      error_message = "Set exactly one of os_image_url (download) or os_image_file_id (pre-existing Proxmox file)."
    }
    precondition {
      condition     = var.vm_ip_address == null || var.vm_gateway != null
      error_message = "vm_gateway is required when vm_ip_address is set."
    }
  }

  # qemu-guest-agent is required for kube-status / kube-kubeconfig (qm guest exec).
  agent {
    enabled = true
    timeout = "15m"
    trim    = true
  }


  cpu {
    cores = var.vm_cores
    numa  = var.vm_numa
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  # Import the cloud image into disk storage on VM creation.
  # Always use import_from (PVE 9 import API path) — never file_id. The file_id path
  # triggers ipcc_send_rec ACL-load failures with non-root PAM tokens (bpg/proxmox
  # provider limitation). For a pre-existing image (os_image_file_id), pass the
  # Proxmox file reference directly to import_from — it accepts both download IDs
  # and pre-existing content_type=import file references.
  disk {
    datastore_id = var.disk_datastore_id
    import_from  = var.os_image_url != null ? one(proxmox_download_file.os_image[*].id) : var.os_image_file_id
    file_id      = null
    interface    = "scsi0"
    size         = var.vm_disk_gb
    discard      = "on"
    iothread     = true
  }

  serial_device {}

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
    queues = var.vm_cores  # multi-queue: distribute NIC interrupts across all vCPUs
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id         = var.disk_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.cloud_init.id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.network_data.id
  }
}
