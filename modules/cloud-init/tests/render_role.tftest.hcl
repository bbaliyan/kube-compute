# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-almalinux-10.yaml.tpl"
}

run "server_init_default_uses_etcd" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "cat >/etc/rancher/rke2/config.yaml")
    error_message = "server-init must write RKE2's config.yaml (RKE2 has no K3s-style exec-string env var)"
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
    condition     = !strcontains(nonsensitive(output.cloud_init), "server: https://")
    error_message = "default node_role (server-init, no registration_address) must never render a server: join line — omitting it is what makes RKE2 initialize instead of join"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "node-taint:")
    error_message = "control_plane_taint defaults to false; no node-taint key should render"
  }
}

run "control_plane_taint_adds_node_taint" {
  command = plan

  variables {
    cluster_name        = "test1"
    k8s_version         = "v1.36.1+rke2r1"
    control_plane_taint = true
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "node-taint:") && strcontains(nonsensitive(output.cloud_init), "CriticalAddonsOnly=true:NoExecute")
    error_message = "control_plane_taint=true must render the CriticalAddonsOnly taint under a node-taint: key"
  }
}

run "server_init_wires_cluster_tokens" {
  command = plan

  variables {
    cluster_name        = "test1"
    k8s_version         = "v1.36.1+rke2r1"
    cluster_token       = "cluster-secret-abc123"
    cluster_agent_token = "agent-secret-xyz789"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "token: cluster-secret-abc123")
    error_message = "server-init must set config.yaml's token: from cluster_token so servers/agents share the base join secret"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "agent-token: agent-secret-xyz789")
    error_message = "server-init must configure a separate agent-token: so a worker's token can never be used to join as a server"
  }
}

run "worker_role_renders_agent_join" {
  command = plan

  variables {
    cluster_name              = "test1"
    k8s_version               = "v1.36.1+rke2r1"
    node_role                 = "worker"
    registration_address      = "10.0.1.5"
    agent_token_fetch_command = "aws ssm get-parameter --name /kube-compute/test1/agent-token --with-decryption --query Parameter.Value --output text --region eu-west-1"
    node_labels               = { "topology.kubernetes.io/zone" = "eu-west-1a" }
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "server: https://10.0.1.5:9345")
    error_message = "worker role must render the agent join pointed at registration_address on RKE2's supervisor port (9345, not the 6443 apiserver port)"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "aws ssm get-parameter")
    error_message = "worker role must render agent_token_fetch_command verbatim so the token is fetched at boot, not embedded"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "node-label:") && strcontains(nonsensitive(output.cloud_init), "\"topology.kubernetes.io/zone=eu-west-1a\"")
    error_message = "worker role must render every entry of node_labels as a node-label: list item"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "INSTALL_RKE2_TYPE=\"agent\"")
    error_message = "worker role must install RKE2 in agent mode"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "token: $AGENT_TOKEN")
    error_message = "worker role's config.yaml must use the runtime-fetched $AGENT_TOKEN, not a value baked in at render time"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "systemctl enable rke2-agent.service") && strcontains(nonsensitive(output.cloud_init), "systemctl start rke2-agent.service")
    error_message = "worker role must explicitly enable and start rke2-agent.service — RKE2's install script does not auto-start it the way K3s's does"
  }
}

run "invalid_role_rejected" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
    node_role    = "bogus"
  }

  expect_failures = [var.node_role]
}

run "server_join_renders_join_install" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    node_role            = "server-join"
    registration_address = "10.0.1.10"
    cluster_token        = "cluster-secret-join1"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "server: https://10.0.1.10:9345")
    error_message = "server-join must render a plain server join against registration_address on RKE2's supervisor port (9345)"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "token: cluster-secret-join1")
    error_message = "server-join must set config.yaml's token: from cluster_token"
  }
}

run "server_join_staggers_and_self_heals_on_join_race" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    node_role            = "server-join"
    registration_address = "10.0.1.10"
    cluster_token        = "cluster-secret-join1"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "NODE_INDEX=\"$(hostname | grep -oE '[0-9]+$' || echo 0)\"")
    error_message = "server-join must stagger its install by a per-node index parsed from the hostname, so concurrently-created siblings don't race the embedded-etcd single-learner limit (an upstream etcd constraint RKE2 inherits, same as K3s)"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "sleep $((NODE_INDEX * 60))")
    error_message = "server-join must sleep proportionally to its node index before installing"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "rm -rf /var/lib/rancher/rke2/server/tls /var/lib/rancher/rke2/server/cred /var/lib/rancher/rke2/server/db")
    error_message = "a losing join must wipe TLS, credentials, AND any partially-written etcd data (server/db) before retrying — leaving server/db behind can make every retry fail for a different (etcd WAL/member-ID) reason"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "status \"FAILED:k8s-install-join-race\"")
    error_message = "server-join must report a distinct FAILED status when it exhausts its join retries"
  }
}

run "server_init_runtime_probe_present" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    registration_address = "10.0.1.10"
    cluster_token        = "cluster-secret-probe"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "PROBE_CODE=")
    error_message = "server-init must probe the registration endpoint at boot when one is configured"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "SERVER_LINE=\"server: https://10.0.1.10:9345\"")
    error_message = "the probe's rejoin branch must set SERVER_LINE so the replaced genesis node joins rather than re-initializes"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "SERVER_LINE=\"\"")
    error_message = "the probe's genesis (unreachable) branch must still be present — SERVER_LINE stays empty, config.yaml gets no server: key, RKE2 initializes"
  }
}

run "argo_manifests_only_on_server_init" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    node_role            = "server-join"
    registration_address = "10.0.1.10"
    cluster_token        = "cluster-secret-argo"
    gitops_root_repo_url = "https://github.com/example/kube-apps.git"
    # Isolate this assertion from Cilium's own (legitimately server-join-rendered)
    # HelmChart manifest — both features emit "kind: HelmChart", so this test
    # scopes to Argo's own unique chart identifier instead of the generic kind.
    cni = "default"
  }

  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "chart: argo-cd")
    error_message = "Argo/root bootstrap manifests must never render for server-join, even if gitops_root_repo_url is set — they belong on the first server only"
  }
}

run "extra_tls_sans_rendered_for_server_init" {
  command = plan

  variables {
    cluster_name   = "test1"
    k8s_version    = "v1.36.1+rke2r1"
    extra_tls_sans = ["cp-lb.internal.example.test", "*.bharat.example.test"]
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "- cp-lb.internal.example.test")
    error_message = "extra_tls_sans entries must each render as a tls-san: list item"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "- *.bharat.example.test")
    error_message = "a wildcard entry in extra_tls_sans must render verbatim"
  }
}

run "kubeconfig_prefers_registration_address" {
  command = plan

  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
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

run "etcd_snapshot_disabled_by_default" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
  }

  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "etcd-snapshot-schedule-cron:")
    error_message = "etcd_snapshot_enabled defaults to false; no snapshot keys should render"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "etcd-s3:")
    error_message = "no etcd-s3: key when snapshots are disabled"
  }
}

run "etcd_snapshot_schedule_renders_for_server_init" {
  command = plan

  variables {
    cluster_name                = "test1"
    k8s_version                 = "v1.36.1+rke2r1"
    etcd_snapshot_enabled       = true
    etcd_snapshot_schedule_cron = "0 */6 * * *"
    etcd_snapshot_retention     = 10
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "etcd-snapshot-schedule-cron: '0 */6 * * *'")
    error_message = "etcd_snapshot_schedule_cron must render verbatim as etcd-snapshot-schedule-cron:"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "etcd-snapshot-retention: 10")
    error_message = "etcd_snapshot_retention must render as etcd-snapshot-retention:"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "etcd-s3:")
    error_message = "no etcd-s3: key when no object-store bucket is given, even with snapshots enabled"
  }
}

run "etcd_snapshot_object_store_renders_s3_flags" {
  command = plan

  variables {
    cluster_name                        = "test1"
    k8s_version                         = "v1.36.1+rke2r1"
    etcd_snapshot_enabled               = true
    etcd_snapshot_object_store_bucket   = "kube-compute-test1-snapshots"
    etcd_snapshot_object_store_region   = "eu-west-1"
    etcd_snapshot_object_store_endpoint = "https://s3.eu-west-1.amazonaws.com"
    etcd_snapshot_object_store_folder   = "test1"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "etcd-s3: true") && strcontains(nonsensitive(output.cloud_init), "etcd-s3-bucket: kube-compute-test1-snapshots")
    error_message = "an object-store bucket must render etcd-s3: true and etcd-s3-bucket:"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "etcd-s3-region: eu-west-1")
    error_message = "etcd_snapshot_object_store_region must render as etcd-s3-region:"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "etcd-s3-endpoint: https://s3.eu-west-1.amazonaws.com")
    error_message = "etcd_snapshot_object_store_endpoint must render as etcd-s3-endpoint:"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "etcd-s3-folder: test1")
    error_message = "etcd_snapshot_object_store_folder must render as etcd-s3-folder:"
  }
}

run "etcd_snapshot_renders_identically_for_server_join" {
  command = plan

  variables {
    cluster_name            = "test1"
    k8s_version             = "v1.36.1+rke2r1"
    node_role               = "server-join"
    registration_address    = "10.0.1.10"
    cluster_token           = "cluster-secret-snap"
    etcd_snapshot_enabled   = true
    etcd_snapshot_retention = 7
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "etcd-snapshot-retention: 7")
    error_message = "server-join must render the same snapshot keys as server-init"
  }
}
