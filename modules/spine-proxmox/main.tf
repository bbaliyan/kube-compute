# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init_template = coalesce(var.cloud_init_template, "${path.module}/../node-bootstrap/templates/cloud-init-ubuntu-2604.yaml.tpl")

  has_domain    = var.cluster_domain != null
  fqdn_suffix   = local.has_domain ? "${var.cluster_name}.${var.cluster_domain}" : null
  cluster_fqdn  = local.has_domain ? "api.${local.fqdn_suffix}" : null
  wildcard_name = local.has_domain ? "*.${local.fqdn_suffix}" : null

  control_plane_taint              = var.cluster_type == "dedicated_control_plane"
  effective_cni                    = var.cni != null ? var.cni : (var.control_plane_count > 1 ? "cilium" : "flannel")
  effective_etcd_snapshots_enabled = var.etcd_snapshots_enabled != null ? var.etcd_snapshots_enabled : var.control_plane_count > 1

  # Null for control_plane_count = 1 (no registration endpoint — ADR 0003), the VIP otherwise.
  registration_address = var.control_plane_count == 1 ? null : var.control_plane_vip_address

  cluster_ipset_name = "kube-node-${var.cluster_name}-cluster"
  etcd_ipset_name    = "kube-node-${var.cluster_name}-etcd"
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
  comment = "kube-node ${var.cluster_name}: east-west traffic among cluster members (subnet-scoped — see module README)."

  cidr {
    name = coalesce(var.cluster_network_cidr, "${split("/", coalesce(try(var.control_plane_ip_addresses[0], null), "0.0.0.0/32"))[0]}/32")
  }
}

# ---- etcd firewall: exact control-plane IPs only, never joined by workers ----
resource "proxmox_virtual_environment_firewall_ipset" "etcd" {
  name    = local.etcd_ipset_name
  comment = "kube-node ${var.cluster_name}: etcd peer/client traffic, control-plane nodes only."

  dynamic "cidr" {
    for_each = var.control_plane_count > 1 ? [for ip in var.control_plane_ip_addresses : "${split("/", ip)[0]}/32"] : []
    content {
      name = cidr.value
    }
  }
}
