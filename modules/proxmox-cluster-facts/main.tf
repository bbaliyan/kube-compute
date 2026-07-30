# SPDX-License-Identifier: Apache-2.0
module "cluster_facts" {
  source = "../cluster-facts"

  k8s_version = var.k8s_version

  platform_enabled           = var.platform_enabled
  platform_repo_url_override = var.platform_repo_url_override
  platform_revision_override = var.platform_revision_override
  workloads_repo_url         = var.workloads_repo_url
  workloads_revision         = var.workloads_revision
  workloads_path             = var.workloads_path
}

locals {
  # The single source of truth for these two names — proxmox-control-plane still owns
  # the ipset *resources* (Proxmox's firewall API resolves references by name, tolerant
  # of the ipset not existing yet — see this module's README), but both it and
  # proxmox-node-pool need the same name convention, so it lives here, not duplicated in
  # each.
  cluster_ipset_name = "kube-compute-${var.cluster_name}-cluster"
  etcd_ipset_name    = "kube-compute-${var.cluster_name}-etcd"
}
