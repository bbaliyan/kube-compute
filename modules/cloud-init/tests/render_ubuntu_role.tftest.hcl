# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-ubuntu-2604.yaml.tpl"
}

run "server_init_default_uses_etcd" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--cluster-init")
    error_message = "default node_role (server-init) must render --cluster-init"
  }
}

run "control_plane_taint_adds_node_taint" {
  command = plan
  variables {
    cluster_name        = "test1"
    k8s_version         = "v1.36.1+k3s1"
    control_plane_taint = true
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--node-taint CriticalAddonsOnly=true:NoExecute")
    error_message = "control_plane_taint=true must render the taint on Ubuntu just as it does on AL2023"
  }
}

run "server_join_renders_join_install" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+k3s1"
    node_role            = "server-join"
    registration_address = "192.168.1.10"
    cluster_token        = "cluster-secret-join1"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "server --server https://192.168.1.10:6443")
    error_message = "server-join must render a plain server join against registration_address"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "--cluster-init")
    error_message = "server-join must never render --cluster-init"
  }
}

run "server_init_runtime_probe_present" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+k3s1"
    registration_address = "192.168.1.10"
    cluster_token        = "cluster-secret-probe"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "PROBE_CODE=")
    error_message = "server-init must probe the registration endpoint at boot when one is configured, same as AL2023"
  }
}

run "worker_role_renders_agent_join" {
  command = plan
  variables {
    cluster_name              = "test1"
    k8s_version               = "v1.36.1+k3s1"
    node_role                 = "worker"
    registration_address      = "192.168.1.10"
    agent_token_fetch_command = "echo 'agent-secret-xyz789'"
    node_labels               = { "topology.kubernetes.io/zone" = "homelab" }
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "agent --server https://192.168.1.10:6443")
    error_message = "worker role must render the agent join pointed at registration_address"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "echo 'agent-secret-xyz789'")
    error_message = "worker role must render agent_token_fetch_command verbatim"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--node-label topology.kubernetes.io/zone=homelab")
    error_message = "worker role must render node_labels as --node-label flags"
  }
}

run "cilium_manifest_renders_for_server_init" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
    cni          = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "chart: cilium")
    error_message = "cni = cilium must render the Cilium HelmChart CRD on Ubuntu just as it does on AL2023"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--flannel-backend=none")
    error_message = "cni = cilium must render the CNI_ARGS disabling flannel/kube-proxy"
  }
}

run "etcd_snapshot_schedule_renders" {
  command = plan
  variables {
    cluster_name                = "test1"
    k8s_version                 = "v1.36.1+k3s1"
    etcd_snapshot_enabled       = true
    etcd_snapshot_schedule_cron = "0 */6 * * *"
    etcd_snapshot_retention     = 10
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--etcd-snapshot-schedule-cron '0 */6 * * *'")
    error_message = "etcd snapshot flags must render on Ubuntu just as they do on AL2023"
  }
}
