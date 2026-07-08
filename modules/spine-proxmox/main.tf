# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../cloud-init/templates/cloud-init-ubuntu-2604.yaml.tpl")

  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null

  control_plane_taint              = var.cluster_type == "dedicated_control_plane"
  effective_cni                    = var.cni != null ? var.cni : (var.control_plane_count > 1 ? "cilium" : "flannel")
  effective_etcd_snapshots_enabled = var.etcd_snapshots_enabled != null ? var.etcd_snapshots_enabled : var.control_plane_count > 1

  # Null for control_plane_count = 1 (no registration endpoint — ADR 0003), the VIP otherwise.
  registration_address = var.control_plane_count == 1 ? null : var.control_plane_vip_address

  cluster_ipset_name = "kube-compute-${var.cluster_name}-cluster"
  etcd_ipset_name    = "kube-compute-${var.cluster_name}-etcd"

  # One IP per control-plane node; index 0 is genesis. DHCP only when control_plane_count = 1
  # and control_plane_ip_addresses was left null (parity with node-proxmox's existing default).
  static_ips  = var.control_plane_ip_addresses != null
  cp_ip_cidrs = local.static_ips ? var.control_plane_ip_addresses : []

  _dns_list = join(", ", var.dns_servers)

  # Netplan v2 network-config, one per control-plane index. OpenTofu forbids heredocs inside
  # ternaries, so both branches are precomputed and selected per-index below.
  network_data_static = { for i, cidr in local.cp_ip_cidrs : i => <<-EOT
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        addresses:
          - ${cidr}
        routes:
          - to: default
            via: ${var.vm_gateway}
        nameservers:
          addresses: [${local._dns_list}]
        dhcp4: false
    EOT
  }
  network_data_dhcp = <<-EOT
    version: 2
    ethernets:
      primary:
        match:
          name: "en*"
        dhcp4: true
    EOT
}

# ---- Join-token flow: pre-generated so a spine + pool join in one apply pass ----
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}

# ---- Cluster firewall: an ipset scoped to the cluster's L2 subnet CIDR (see plan design note 2) ----
resource "proxmox_virtual_environment_firewall_ipset" "cluster" {
  name    = local.cluster_ipset_name
  comment = "kube-compute ${var.cluster_name}: east-west traffic among cluster members (subnet-scoped — see module README)."

  cidr {
    name = coalesce(var.cluster_network_cidr, "${split("/", coalesce(try(var.control_plane_ip_addresses[0], null), "0.0.0.0/32"))[0]}/32")
  }
}

# ---- etcd firewall: exact control-plane IPs only, never joined by workers ----
resource "proxmox_virtual_environment_firewall_ipset" "etcd" {
  name    = local.etcd_ipset_name
  comment = "kube-compute ${var.cluster_name}: etcd peer/client traffic, control-plane nodes only."

  dynamic "cidr" {
    for_each = var.control_plane_count > 1 ? [for ip in var.control_plane_ip_addresses : "${split("/", ip)[0]}/32"] : ["${local.cp_ips["0"]}/32"]
    content {
      name = cidr.value
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

locals {
  kube_vip_manifest = var.control_plane_count == 1 ? null : <<-EOT
    apiVersion: v1
    kind: ServiceAccount
    metadata:
      name: kube-vip
      namespace: kube-system
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: system:kube-vip-role
    rules:
      - apiGroups: [""]
        resources: ["services", "services/status", "nodes", "endpoints", "configmaps"]
        verbs: ["list", "get", "watch", "update", "create"]
      - apiGroups: ["coordination.k8s.io"]
        resources: ["leases"]
        verbs: ["list", "get", "watch", "update", "create"]
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: system:kube-vip-binding
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: system:kube-vip-role
    subjects:
      - kind: ServiceAccount
        name: kube-vip
        namespace: kube-system
    ---
    apiVersion: apps/v1
    kind: DaemonSet
    metadata:
      name: kube-vip-ds
      namespace: kube-system
    spec:
      selector:
        matchLabels:
          name: kube-vip-ds
      template:
        metadata:
          labels:
            name: kube-vip-ds
        spec:
          serviceAccountName: kube-vip
          tolerations:
            - key: CriticalAddonsOnly
              operator: Exists
            - effect: NoSchedule
              operator: Exists
            - effect: NoExecute
              operator: Exists
          hostNetwork: true
          containers:
            - name: kube-vip
              image: ghcr.io/kube-vip/kube-vip:v0.8.9
              imagePullPolicy: IfNotPresent
              args: ["manager"]
              env:
                - name: vip_arp
                  value: "true"
                - name: port
                  value: "6443"
                - name: vip_cidr
                  value: "32"
                - name: cp_enable
                  value: "true"
                - name: cp_namespace
                  value: "kube-system"
                - name: vip_ddns
                  value: "false"
                - name: svc_enable
                  value: "false"
                - name: vip_leaderelection
                  value: "true"
                - name: vip_leaseduration
                  value: "5"
                - name: vip_renewdeadline
                  value: "3"
                - name: vip_retryperiod
                  value: "1"
                - name: address
                  value: "${var.control_plane_vip_address}"
              securityContext:
                capabilities:
                  add: ["NET_ADMIN", "NET_RAW"]
  EOT
}

module "bootstrap" {
  source = "../cloud-init"

  cloud_init_template            = local.cloud_init_template
  cluster_name                   = var.cluster_name
  k8s_version                    = var.k8s_version
  cluster_fqdn                   = local.cluster_fqdn
  node_role                      = "server-init"
  control_plane_taint            = local.control_plane_taint
  cni                            = local.effective_cni
  cluster_token                  = random_password.server_token.result
  cluster_agent_token            = random_password.agent_token.result
  registration_address           = local.registration_address
  extra_tls_sans                 = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  etcd_snapshot_enabled          = local.effective_etcd_snapshots_enabled
  etcd_snapshot_schedule_cron    = var.etcd_snapshot_schedule_cron
  etcd_snapshot_retention        = var.etcd_snapshot_retention
  extra_server_manifests         = local.kube_vip_manifest != null ? { "kube-vip.yaml" = local.kube_vip_manifest } : {}
  trusted_ca_pem                 = var.trusted_ca_pem
  registry_mirror_url            = var.registry_mirror_url
  gitops_platform_repo_url       = var.gitops_platform_repo_url
  gitops_platform_revision       = var.gitops_platform_revision
  gitops_workloads_repo_url      = var.gitops_workloads_repo_url
  gitops_workloads_revision      = var.gitops_workloads_revision
  gitops_workloads_path          = var.gitops_workloads_path
  cert_mode                      = var.cert_mode
  platform_extra_helm_parameters = var.platform_extra_helm_parameters
  platform_helm_values_object    = var.platform_helm_values_object
  extra_tags                     = var.extra_tags
}

module "bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../cloud-init"

  cloud_init_template         = local.cloud_init_template
  cluster_name                = var.cluster_name
  k8s_version                 = var.k8s_version
  cluster_fqdn                = local.cluster_fqdn
  node_role                   = "server-join"
  control_plane_taint         = local.control_plane_taint
  cni                         = local.effective_cni
  registration_address        = local.registration_address
  extra_tls_sans              = [for v in [local.registration_address, local.wildcard_name] : v if v != null]
  etcd_snapshot_enabled       = local.effective_etcd_snapshots_enabled
  etcd_snapshot_schedule_cron = var.etcd_snapshot_schedule_cron
  etcd_snapshot_retention     = var.etcd_snapshot_retention
  extra_server_manifests      = local.kube_vip_manifest != null ? { "kube-vip.yaml" = local.kube_vip_manifest } : {}
  cluster_token               = random_password.server_token.result
  trusted_ca_pem              = var.trusted_ca_pem
  registry_mirror_url         = var.registry_mirror_url
  cert_mode                   = var.cert_mode
  extra_tags                  = var.extra_tags
  # gitops_* intentionally omitted: Argo/platform bootstrap runs on the first server only.
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

resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = module.bootstrap.cloud_init
    file_name = "${var.cluster_name}-cp-0-cloud-init.yaml"
  }
}

resource "proxmox_virtual_environment_file" "cloud_init_additional" {
  for_each = module.bootstrap_additional

  content_type = "snippets"
  datastore_id = var.iso_datastore_id
  node_name    = var.proxmox_node

  source_raw {
    data      = each.value.cloud_init
    file_name = "${var.cluster_name}-cp-${each.key}-cloud-init.yaml"
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
    user_data_file_id    = proxmox_virtual_environment_file.cloud_init.id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = local.static_ips ? proxmox_virtual_environment_file.network_data["0"].id : proxmox_virtual_environment_file.network_data_dhcp[0].id
  }

  lifecycle {
    precondition {
      condition     = (var.os_image_url != null) != (var.os_image_file_id != null)
      error_message = "Set exactly one of os_image_url (download) or os_image_file_id (pre-existing Proxmox file)."
    }
  }
}

resource "proxmox_virtual_environment_vm" "control_plane_additional" {
  for_each = module.bootstrap_additional

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
    datastore_id         = var.disk_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.cloud_init_additional[each.key].id
    vendor_data_file_id  = proxmox_virtual_environment_file.vendor_data.id
    network_data_file_id = proxmox_virtual_environment_file.network_data[each.key].id
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
