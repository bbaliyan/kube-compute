# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  # Falls back to the platform-wide default when the caller doesn't override k8s_version.
  k8s_version = coalesce(var.k8s_version, module.component_versions.k8s_version)

  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null

  control_plane_taint = var.cluster_type == "dedicated_control_plane"
  effective_cni       = coalesce(var.cni, "cilium")
  # Cilium chart default (2 operator replicas, pod anti-affinity) leaves one
  # replica permanently Pending on a genuinely single-node cluster.
  effective_cilium_operator_replicas = var.control_plane_count > 1 ? null : 1
  effective_etcd_snapshots_enabled   = var.etcd_snapshots_enabled != null ? var.etcd_snapshots_enabled : var.control_plane_count > 1

  # Null for control_plane_count = 1 (no registration endpoint), the VIP otherwise.
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

# ---- Join-token flow: pre-generated so a control plane + pool join in one apply pass ----
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
              # renovate: datasource=docker depName=ghcr.io/kube-vip/kube-vip
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
  k8s_version                    = local.k8s_version
  cluster_fqdn                   = local.cluster_fqdn
  cluster_fqdn_suffix            = local.fqdn_suffix
  node_role                      = "server-init"
  control_plane_taint            = local.control_plane_taint
  cni                            = local.effective_cni
  cilium_operator_replicas       = local.effective_cilium_operator_replicas
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
  gitops_root_repo_url           = var.gitops_root_repo_url
  gitops_root_revision           = var.gitops_root_revision
  gitops_root_path               = var.gitops_root_path
  cert_mode                      = var.cert_mode
  platform_extra_helm_parameters = var.platform_extra_helm_parameters
  platform_helm_values_object    = var.platform_helm_values_object
  extra_tags                     = var.extra_tags

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

# depends_on the genesis node's node-bootstrap run (not just its VM/IP) — see
# aws-control-plane's identical comment on module.node_bootstrap_additional
# for the full reasoning: Ansible's local-exec model has no implicit
# ordering across independent resources the way cloud-init's boot-time
# model did, so this must be explicit here too.
module "node_bootstrap_additional" {
  for_each = var.control_plane_count > 1 ? { for i in range(1, var.control_plane_count) : tostring(i) => i } : {}

  source = "../node-bootstrap"

  depends_on = [module.node_bootstrap]

  ansible_playbook_path       = var.ansible_playbook_path
  cluster_name                = var.cluster_name
  node_name                   = "${var.cluster_name}-cp-${each.key}"
  k8s_version                 = local.k8s_version
  cluster_fqdn                = local.cluster_fqdn
  cluster_fqdn_suffix         = local.fqdn_suffix
  node_role                   = "server-join"
  control_plane_taint         = local.control_plane_taint
  cni                         = local.effective_cni
  cilium_operator_replicas    = local.effective_cilium_operator_replicas
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

  ansible_connection_vars = {
    ansible_connection           = "ssh"
    ansible_host                 = local.cp_ips[each.key]
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
    datastore_id         = var.disk_datastore_id
    user_data_file_id    = proxmox_virtual_environment_file.hostname_init_additional[each.key].id
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
