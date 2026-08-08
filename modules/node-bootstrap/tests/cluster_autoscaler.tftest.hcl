# SPDX-License-Identifier: Apache-2.0
# Guards the cluster_autoscaler_enabled genesis-apply path: disabled (the
# default) must leave zero trace in the rendered payload; enabled must carry
# the rendered MachineDeployment/ProxmoxMachineTemplate/RKE2ConfigTemplate
# bundle, the CAPI-install apply steps in bootstrap.sh, and the exact
# MB->MiB conversion for the ProxmoxMachineTemplate's memoryMiB field.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
}

run "cluster_autoscaler_disabled_by_default_leaves_no_trace" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
  }

  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "cluster_autoscaler_enabled defaults to false — no autoscaler manifest should be written at all"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "capi-install.yaml") &&
      !strcontains(base64decode(f.content), "machinedeployments.cluster.x-k8s.io")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "with cluster_autoscaler_enabled = false, bootstrap.sh must carry no CAPI install/apply lines"
  }
}

run "cluster_autoscaler_enabled_renders_manifest_and_apply_steps" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null

    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 1
    cluster_autoscaler_worker_max_size = 3
    cluster_autoscaler_worker_template = {
      vm_cores               = 4
      vm_memory_mb           = 4096
      vm_disk_gb             = 40
      proxmox_template_vm_id = 9100
      network_bridge         = "vmbr0"
      disk_datastore_id      = "local-lvm"
      proxmox_node           = "pve1"
    }
  }

  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "cluster_autoscaler_enabled = true on a server-init node must write the autoscaler workers manifest"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "memoryMiB: 3907")
      if f.path == "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    ])
    error_message = "vm_memory_mb = 4096 must convert to memoryMiB = ceil(4096 * 1000000 / 1048576) = 3907"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "name: test-autoscaler-workers") &&
      strcontains(base64decode(f.content), "templateID: 9100") &&
      strcontains(base64decode(f.content), "sourceNode: pve1") &&
      strcontains(base64decode(f.content), "storage: local-lvm") &&
      strcontains(base64decode(f.content), "bridge: vmbr0")
      if f.path == "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    ])
    error_message = "the rendered manifest must carry the cluster name and the worker template's Proxmox fields"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "$KUBECTL apply -f \"$KC/manifests/capi-install.yaml\"") &&
      strcontains(base64decode(f.content), "machinedeployments.cluster.x-k8s.io") &&
      strcontains(base64decode(f.content), "$KUBECTL apply -f \"$KC/manifests/20-cluster-autoscaler-workers.yaml\"")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "bootstrap.sh must apply the baked capi-install.yaml, wait for CAPI's CRDs, then apply the autoscaler workers manifest"
  }
}

run "cluster_autoscaler_enabled_without_template_fails_validation" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null

    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 1
    cluster_autoscaler_worker_max_size = 3
    # cluster_autoscaler_worker_template left at its null default.
  }

  expect_failures = [var.cluster_autoscaler_worker_template]
}

run "cluster_autoscaler_enabled_with_zero_max_size_fails_validation" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null

    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 0
    # cluster_autoscaler_worker_max_size left at its 0 default.
    cluster_autoscaler_worker_template = {
      vm_cores               = 4
      vm_memory_mb           = 4096
      vm_disk_gb             = 40
      proxmox_template_vm_id = 9100
      network_bridge         = "vmbr0"
      disk_datastore_id      = "local-lvm"
      proxmox_node           = "pve1"
    }
  }

  expect_failures = [var.cluster_autoscaler_worker_max_size]
}

run "cluster_autoscaler_worker_node_never_renders_the_genesis_apply" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"

    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 1
    cluster_autoscaler_worker_max_size = 3
    cluster_autoscaler_worker_template = {
      vm_cores               = 4
      vm_memory_mb           = 4096
      vm_disk_gb             = 40
      proxmox_template_vm_id = 9100
      network_bridge         = "vmbr0"
      disk_datastore_id      = "local-lvm"
      proxmox_node           = "pve1"
    }
  }

  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    )
    error_message = "the genesis CAPI apply is server-init-only — a plain worker must never carry it, even with cluster_autoscaler_enabled = true"
  }
}
