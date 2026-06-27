# SPDX-License-Identifier: Apache-2.0

locals {
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
# content_type="import" uses the PVE 9 import API path (POST .../download-url with content=import),
# which avoids the ipcc_send_rec / ACL-load failure that occurs with content_type="iso" + file_id
# when the API token is a non-root PAM token.
resource "proxmox_download_file" "os_image" {
  count = var.os_image_url != null ? 1 : 0

  content_type        = "import"
  datastore_id        = var.iso_datastore_id
  node_name           = var.proxmox_node
  url                 = var.os_image_url
  file_name           = "${var.cluster_name}.qcow2"
  overwrite_unmanaged = false
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
    data      = "#cloud-config\npackages:\n  - qemu-guest-agent\nruncmd:\n  - systemctl enable --now qemu-guest-agent\n"
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
  # import_from (used with content_type="import") uses the PVE 9 import API and avoids
  # the ipcc ACL-load failure. file_id is used only when os_image_file_id is pre-provided.
  disk {
    datastore_id = var.disk_datastore_id
    import_from  = var.os_image_url != null ? one(proxmox_download_file.os_image[*].id) : null
    file_id      = var.os_image_file_id
    interface    = "scsi0"
    size         = var.vm_disk_gb
    discard      = "on"
    iothread     = true
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id        = var.disk_datastore_id
    user_data_file_id   = proxmox_virtual_environment_file.cloud_init.id
    vendor_data_file_id = proxmox_virtual_environment_file.vendor_data.id

    ip_config {
      ipv4 {
        address = var.vm_ip_address != null ? var.vm_ip_address : "dhcp"
        gateway = var.vm_ip_address != null ? var.vm_gateway : null
      }
    }
  }
}
