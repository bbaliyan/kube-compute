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

run "server_init_wires_cluster_tokens" {
  command = plan

  variables {
    cluster_name        = "test1"
    k8s_version         = "v1.36.1+k3s1"
    cluster_token       = "cluster-secret-abc123"
    cluster_agent_token = "agent-secret-xyz789"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "INSTALL_K3S_TOKEN=\"cluster-secret-abc123\"")
    error_message = "server-init must set INSTALL_K3S_TOKEN from cluster_token so servers/agents share the base join secret"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--agent-token agent-secret-xyz789")
    error_message = "server-init must configure a separate --agent-token so a worker's token can never be used to join as a server"
  }
}

run "worker_role_renders_agent_join" {
  command = plan

  variables {
    cluster_name              = "test1"
    k8s_version               = "v1.36.1+k3s1"
    node_role                 = "worker"
    registration_address      = "10.0.1.5"
    agent_token_fetch_command = "aws ssm get-parameter --name /kube-node/test1/agent-token --with-decryption --query Parameter.Value --output text --region eu-west-1"
    node_labels               = { "topology.kubernetes.io/zone" = "eu-west-1a" }
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--server https://10.0.1.5:6443")
    error_message = "worker role must render the agent join pointed at registration_address"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "aws ssm get-parameter")
    error_message = "worker role must render agent_token_fetch_command verbatim so the token is fetched at boot, not embedded"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--node-label topology.kubernetes.io/zone=eu-west-1a")
    error_message = "worker role must render every entry of node_labels as a --node-label flag"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "--cluster-init")
    error_message = "a worker must never render server-only flags (--cluster-init)"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "agent --server https://10.0.1.5:6443")
    error_message = "sanity: the assembled agent exec string must be present"
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

run "server_join_renders_join_install" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+k3s1"
    node_role            = "server-join"
    registration_address = "10.0.1.10"
    cluster_token        = "cluster-secret-join1"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "server --server https://10.0.1.10:6443")
    error_message = "server-join must render a plain server join against registration_address"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "INSTALL_K3S_TOKEN=\"cluster-secret-join1\"")
    error_message = "server-join must set INSTALL_K3S_TOKEN from cluster_token"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "--cluster-init")
    error_message = "server-join must never render --cluster-init (that would form a second, split-brain etcd cluster)"
  }
}

run "server_init_runtime_probe_present" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+k3s1"
    registration_address = "10.0.1.10"
    cluster_token        = "cluster-secret-probe"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "PROBE_CODE=")
    error_message = "server-init must probe the registration endpoint at boot when one is configured"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "server --server https://10.0.1.10:6443")
    error_message = "the probe's rejoin branch must be present in the rendered script"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "server --cluster-init")
    error_message = "the probe's genesis (unreachable) branch must still be present in the rendered script"
  }
}

run "argo_manifests_only_on_server_init" {
  command = plan

  variables {
    cluster_name             = "test1"
    k8s_version              = "v1.36.1+k3s1"
    node_role                = "server-join"
    registration_address     = "10.0.1.10"
    cluster_token            = "cluster-secret-argo"
    gitops_platform_repo_url = "https://github.com/example/kube-platform.git"
  }

  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "kind: HelmChart")
    error_message = "Argo/platform bootstrap manifests must never render for server-join, even if gitops_platform_repo_url is set — they belong on the first server only"
  }
}

run "extra_tls_sans_rendered_for_server_init" {
  command = plan

  variables {
    cluster_name   = "test1"
    k8s_version    = "v1.36.1+k3s1"
    extra_tls_sans = ["cp-lb.internal.example.test", "*.bharat.example.test"]
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--tls-san cp-lb.internal.example.test")
    error_message = "extra_tls_sans entries must each render as a --tls-san flag"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--tls-san *.bharat.example.test")
    error_message = "a wildcard entry in extra_tls_sans must render verbatim"
  }
}

run "kubeconfig_prefers_registration_address" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+k3s1"
    cluster_fqdn         = "api.bharat.example.test"
    registration_address = "cp-lb.internal.example.test"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "REGISTRATION_ADDRESS=\"cp-lb.internal.example.test\"")
    error_message = "REGISTRATION_ADDRESS must be written to the env file when set"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "[ -n \"$REGISTRATION_ADDRESS\" ] && SERVER=\"$REGISTRATION_ADDRESS\"")
    error_message = "kubeconfig publish must prefer REGISTRATION_ADDRESS over CLUSTER_FQDN/NODE_IP so it survives a control-plane node dying"
  }
}
