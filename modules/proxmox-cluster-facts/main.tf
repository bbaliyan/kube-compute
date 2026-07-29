# SPDX-License-Identifier: Apache-2.0
module "cluster_facts" {
  source = "../cluster-facts"

  k8s_version = var.k8s_version
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
