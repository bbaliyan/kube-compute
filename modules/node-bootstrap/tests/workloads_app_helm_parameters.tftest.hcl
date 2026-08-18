# SPDX-License-Identifier: Apache-2.0
# workloads_extra_helm_parameters lets a caller pass a workload chart's
# per-cluster identity (region, FQDN, bucket name, ...) as Helm parameters on
# the rendered workloads Application, instead of that chart's own repo
# hand-typing (and drifting) the same values. Covers: a dotted parameter name
# reaches the nested value Helm's --set syntax implies, and the helm block is
# omitted entirely when the map is empty (no dangling `helm:` key).

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
}

run "workloads_app_helm_parameters_render_nested_and_flat" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_workloads_repo_url = "https://example.test/workloads.git"
    gitops_workloads_path     = "cluster-sql"
    workloads_extra_helm_parameters = {
      "backup.bucketName" = "xtpc-icrq-1717-database-backups-us-east-1"
      "clusterFqdnSuffix" = "cluster-sql.us-east-1.1717.aws.iongroup.net"
    }
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      can(yamldecode(base64decode(f.content)).spec.source.helm.parameters) &&
      anytrue([
        for p in yamldecode(base64decode(f.content)).spec.source.helm.parameters :
        p.name == "backup.bucketName" && p.value == "xtpc-icrq-1717-database-backups-us-east-1"
      ])
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "a dotted workloads_extra_helm_parameters key must render verbatim as a name: under spec.source.helm.parameters"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      anytrue([
        for p in yamldecode(base64decode(f.content)).spec.source.helm.parameters :
        p.name == "clusterFqdnSuffix" && p.value == "cluster-sql.us-east-1.1717.aws.iongroup.net"
      ])
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "every workloads_extra_helm_parameters entry must render, not just the first"
  }
}

run "workloads_app_omits_helm_block_when_no_extra_parameters" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_workloads_repo_url = "https://example.test/workloads.git"
    gitops_workloads_path     = "cluster-sql"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !can(yamldecode(base64decode(f.content)).spec.source.helm)
      if f.path == "/opt/kube-compute/manifests/11-workloads-app.yaml"
    ])
    error_message = "spec.source.helm must be absent entirely when workloads_extra_helm_parameters is empty (the default) — no dangling 'helm:' key"
  }
}
