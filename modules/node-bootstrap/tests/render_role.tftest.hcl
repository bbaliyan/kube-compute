# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-al2023.yaml.tpl"
}

run "server_init_default_uses_etcd" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--cluster-init")
    error_message = "default node_role (server-init) must render --cluster-init (embedded etcd)"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "stage-4:k8s-install")
    error_message = "core install stage must still be present"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "stage-7:kubeconfig-publish")
    error_message = "kubeconfig-publish stage must still be present"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "--node-taint")
    error_message = "control_plane_taint defaults to false; no taint flag should render"
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
    error_message = "control_plane_taint=true must render the CriticalAddonsOnly taint"
  }
}

run "unimplemented_role_fails_fast" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
    node_role    = "worker"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "FAILED:node-role-unimplemented")
    error_message = "a node_role not yet implemented must fail fast with a clear status, not render a broken install"
  }
}

run "invalid_role_rejected" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
    node_role    = "bogus"
  }

  expect_failures = [var.node_role]
}
