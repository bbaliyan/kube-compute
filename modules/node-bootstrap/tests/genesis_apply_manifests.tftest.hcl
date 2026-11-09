# SPDX-License-Identifier: Apache-2.0
# Guards the generic genesis_apply_manifests mechanism: disabled (the default,
# empty list) must leave zero trace in the rendered payload; populated must carry
# every write_files entry the caller listed plus the ordered-apply step in
# bootstrap.sh, server-init only.

variables {
  argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
  argocd_manifest_sha256 = "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4"
  cluster_name           = "test"
  node_name              = "test-cp-0"
}

run "genesis_apply_manifests_empty_by_default_leaves_no_trace" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
  }

  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-extra-manifest.yaml"
    )
    error_message = "genesis_apply_manifests defaults to an empty list — nothing beyond the platform/workloads Applications should be written"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "GENESIS_APPLY_MANIFESTS=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "with genesis_apply_manifests empty (the default), the node must be told to apply nothing"
  }
}

run "genesis_apply_manifests_renders_entries_and_apply_steps" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null

    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20-extra-manifest.yaml"
        content = "kind: Cluster\nname: test-extra\n"
      }
    ]
  }

  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-extra-manifest.yaml"
    )
    error_message = "a genesis_apply_manifests entry on a server-init node must be written via write_files"
  }
  # Compared against base64gzip of the input rather than decoded, because a
  # genesis manifest is written gz+b64 to stay inside EC2's user-data cap and HCL
  # has no gunzip. Byte equality proves the content was not interpreted, which is
  # what this guards.
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      f.encoding == "gz+b64" &&
      f.content == base64gzip("kind: Cluster\nname: test-extra\n")
      if f.path == "/opt/kube-compute/manifests/20-extra-manifest.yaml"
    ])
    error_message = "this module must not interpret genesis_apply_manifests content — it must be written back out verbatim, compressed but unaltered"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "GENESIS_APPLY_MANIFESTS='/opt/kube-compute/manifests/20-extra-manifest.yaml'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "the node must be told which manifests to apply in order"
  }
  # The other half of that contract, in the program rather than the payload.
  assert {
    condition = alltrue([
      for line in [
        "for manifest_path in $GENESIS_APPLY_MANIFESTS",
      ] : strcontains(local.bootstrap_program, line)
    ])
    error_message = "the bootstrap program must still apply the listed manifests in order"
  }
}

run "genesis_apply_manifests_worker_node_never_renders_the_genesis_apply" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"

    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20-extra-manifest.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/20-extra-manifest.yaml"
    )
    error_message = "the genesis apply mechanism is server-init-only — a plain worker must never carry it, even with genesis_apply_manifests populated"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "GENESIS_APPLY_MANIFESTS=''")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "a worker must never be handed manifests to apply, even with genesis_apply_manifests populated"
  }
}

run "set_hostname_true_default_includes_hostname_and_fqdn" {
  command = plan

  variables {
    node_role           = "server-init"
    cluster_token       = "SUPERSECRETTOKEN123"
    cluster_agent_token = "SUPERSECRETAGENT456"
    cluster_fqdn_suffix = "test.example"
  }

  assert {
    condition     = yamldecode(output.cloud_init_user_data).hostname == "test-cp-0"
    error_message = "set_hostname defaults to true — hostname must be written, preserving today's behavior for every existing caller"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).fqdn == "test-cp-0.test.example"
    error_message = "set_hostname defaults to true — fqdn must be written when cluster_fqdn_suffix is set"
  }
}

run "set_hostname_false_omits_hostname_and_fqdn" {
  command = plan

  variables {
    node_role           = "server-init"
    cluster_token       = "SUPERSECRETTOKEN123"
    cluster_agent_token = "SUPERSECRETAGENT456"
    cluster_fqdn_suffix = "test.example"
    set_hostname        = false
  }

  assert {
    condition     = !contains(keys(yamldecode(output.cloud_init_user_data)), "hostname")
    error_message = "set_hostname = false must omit hostname entirely — a shared cloud-init payload (e.g. an Auto Scaling group's instances) cannot carry a node-unique hostname"
  }
  assert {
    condition     = !contains(keys(yamldecode(output.cloud_init_user_data)), "fqdn")
    error_message = "set_hostname = false must omit fqdn entirely, even when cluster_fqdn_suffix is set"
  }
}

# Path validation: bootstrap.sh word-splits the list and the caller must not
# be able to write outside the manifests directory.

run "genesis_apply_manifests_accepts_a_nested_path" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null

    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/sub/20-extra.v1..2.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }
}

run "genesis_apply_manifests_rejects_whitespace_in_a_path" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20 extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_tab_in_a_path" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/20\textra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_relative_path" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    genesis_apply_manifests = [
      {
        path    = "manifests/20-extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_dotdot_segment" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/../../etc/20-extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_path_outside_the_directory" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    genesis_apply_manifests = [
      {
        path    = "/etc/20-extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_sibling_directory_with_the_same_prefix" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests-extra/20-extra.yaml"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}

run "genesis_apply_manifests_rejects_the_directory_itself" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    gitops_platform_enabled   = false
    gitops_platform_repo_url  = "https://example.test/platform.git"
    gitops_workloads_repo_url = null
    genesis_apply_manifests = [
      {
        path    = "/opt/kube-compute/manifests/"
        content = "kind: Cluster\n"
      }
    ]
  }

  expect_failures = [var.genesis_apply_manifests]
}
