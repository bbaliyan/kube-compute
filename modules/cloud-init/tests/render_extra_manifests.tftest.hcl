# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-al2023.yaml.tpl"
}

run "extra_server_manifests_rendered_for_server_init" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
    extra_server_manifests = {
      "kube-vip.yaml" = "apiVersion: apps/v1\nkind: DaemonSet\n"
    }
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "/var/lib/rancher/k3s/server/manifests/kube-vip.yaml")
    error_message = "extra_server_manifests keys must render as file paths under the k3s auto-deploy manifests directory"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "kind: DaemonSet")
    error_message = "extra_server_manifests values must render verbatim as file content"
  }
}

run "extra_server_manifests_absent_for_worker" {
  command = plan

  variables {
    cluster_name              = "test1"
    k8s_version               = "v1.36.1+k3s1"
    node_role                 = "worker"
    registration_address      = "10.0.1.5"
    agent_token_fetch_command = "echo token"
    extra_server_manifests = {
      "kube-vip.yaml" = "apiVersion: apps/v1\nkind: DaemonSet\n"
    }
  }

  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "kube-vip.yaml")
    error_message = "extra_server_manifests must never render for node_role = worker (a worker has no K3s server manifests directory)"
  }
}
