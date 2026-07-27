# SPDX-License-Identifier: Apache-2.0
# Guards the operator_connect / on_node invocation split (see the
# single-Ansible-bootstrap effort). The bundle must be self-contained, carry no
# secrets, and gate the genesis helm render to server-init.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
  k8s_version  = "v1.36.2+rke2r1"
}

run "operator_connect_default_no_bundle" {
  command = plan

  variables {
    node_role     = "server-init"
    cluster_token = "operatorsecret"
  }

  assert {
    condition     = output.on_node_bundle == null
    error_message = "operator_connect must not render an on_node bundle"
  }
  assert {
    condition     = output.bootstrap_log_path == "/tmp/kube-compute-bootstrap-test-cp-0.log"
    error_message = "operator_connect must expose the tee'd log path"
  }
}

run "on_node_server_init_renders_self_contained_bundle" {
  command = plan

  variables {
    invocation_mode      = "on_node"
    node_role            = "server-init"
    cluster_token        = "SUPERSECRETTOKEN123"
    cluster_agent_token  = "SUPERSECRETAGENT456"
    gitops_root_repo_url = "https://example.test/root.git"
  }

  # self-contained + on-node execution
  assert {
    condition     = strcontains(output.on_node_bundle, "dnf install -y ansible-core")
    error_message = "on_node bundle must install ansible-core on the node"
  }
  assert {
    condition     = strcontains(output.on_node_bundle, "-c local")
    error_message = "on_node bundle must run ansible against localhost (-c local)"
  }
  # genesis helm render present for server-init + cilium (default cni)
  assert {
    condition     = strcontains(output.on_node_bundle, "template cilium cilium")
    error_message = "server-init on_node bundle must render the Cilium genesis manifest"
  }
  assert {
    condition     = strcontains(output.on_node_bundle, "template argocd argo-cd")
    error_message = "server-init on_node bundle with a gitops repo must render Argo CD"
  }
  # SECRETS MUST NOT be in the bundle — they flow via run-command protected params
  assert {
    condition     = !strcontains(output.on_node_bundle, "SUPERSECRETTOKEN123")
    error_message = "cluster_token leaked into the on_node bundle"
  }
  assert {
    condition     = !strcontains(output.on_node_bundle, "SUPERSECRETAGENT456")
    error_message = "cluster_agent_token leaked into the on_node bundle"
  }
  # on_node mode runs no local-exec resource
  assert {
    condition     = output.bootstrap_id == null && output.bootstrap_log_path == null
    error_message = "on_node mode must not create the operator_connect null_resource"
  }
}

run "on_node_worker_skips_genesis_helm_render" {
  command = plan

  variables {
    invocation_mode      = "on_node"
    node_role            = "worker"
    registration_address = "10.0.0.10"
  }

  assert {
    condition     = !strcontains(output.on_node_bundle, "template cilium cilium")
    error_message = "worker on_node bundle must not render the Cilium genesis manifest"
  }
  assert {
    condition     = !strcontains(output.on_node_bundle, "template argocd argo-cd")
    error_message = "worker on_node bundle must not render Argo CD"
  }
}
