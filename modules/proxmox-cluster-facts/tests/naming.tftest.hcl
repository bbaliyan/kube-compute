# SPDX-License-Identifier: Apache-2.0
run "ipset_names_follow_the_naming_convention" {
  command = plan
  variables {
    cluster_name = "bharat"
  }

  assert {
    condition     = output.cluster_ipset_name == "kube-compute-bharat-cluster"
    error_message = "cluster_ipset_name must follow the kube-compute-<cluster_name>-cluster convention that proxmox-control-plane and proxmox-node-pool both depend on"
  }
  assert {
    condition     = output.etcd_ipset_name == "kube-compute-bharat-etcd"
    error_message = "etcd_ipset_name must follow the kube-compute-<cluster_name>-etcd convention that proxmox-control-plane and proxmox-node-pool both depend on"
  }
}
