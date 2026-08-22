# SPDX-License-Identifier: Apache-2.0
# Guards the genesis_apply_manifests/cluster_autoscaler_crd_wait_enabled/
# extra_server_manifests pass-throughs: this module owns none of the
# cluster-autoscaler rendering itself (proxmox-cluster does, see that
# module's own cluster_autoscaler tests) — it is a pure forward of these
# variables into its own genesis module "node_bootstrap" call, the same
# pattern every other node-bootstrap variable already gets here.
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}
mock_provider "dns" {}

variables {
  cluster_name          = "bharat"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  os_image_url          = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name    = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "defaults_produce_no_genesis_apply_content" {
  command = apply

  assert {
    condition = !contains(
      [for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "genesis_apply_manifests/cluster_autoscaler_crd_wait_enabled default to empty/false — nothing extra should be written"
  }
}

run "genesis_apply_manifests_thread_through_to_node_bootstrap" {
  command = apply

  variables {
    cluster_autoscaler_crd_wait_enabled = true
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
        content = "kind: Cluster\nname: bharat-autoscaler-workers\n"
      }
    ]
  }

  assert {
    condition = contains(
      [for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "a genesis_apply_manifests entry passed to this module must reach its own genesis node_bootstrap call's write_files"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "kind: Cluster") &&
      strcontains(base64decode(f.content), "name: bharat-autoscaler-workers")
      if f.path == "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    ])
    error_message = "the entry's content must be forwarded verbatim, unmodified by this module"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "$KUBECTL apply -f \"$KC/manifests/capi-install.yaml\"")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "cluster_autoscaler_crd_wait_enabled = true must reach bootstrap.sh's CAPI-install/CRD-wait apply step"
  }
}

run "extra_server_manifests_thread_through_to_node_bootstrap" {
  command = apply

  variables {
    extra_server_manifests = {
      "20-coredns-lan-forward.yaml" = "kind: HelmChartConfig\nname: rke2-coredns\n"
    }
  }

  assert {
    condition = contains(
      [for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files : f.path],
      "/opt/kube-compute/server-manifests/20-coredns-lan-forward.yaml"
    )
    error_message = "an extra_server_manifests entry passed to this module must reach its own genesis node_bootstrap call's write_files"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(proxmox_virtual_environment_file.node_init.source_raw[0].data).write_files :
      strcontains(base64decode(f.content), "kind: HelmChartConfig") &&
      strcontains(base64decode(f.content), "name: rke2-coredns")
      if f.path == "/opt/kube-compute/server-manifests/20-coredns-lan-forward.yaml"
    ])
    error_message = "the entry's content must be forwarded verbatim, unmodified by this module"
  }
}
