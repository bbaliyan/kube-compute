# SPDX-License-Identifier: Apache-2.0
# The Argo CD manifest is downloaded by bootstrap.sh at first boot. This module
# only passes its URL and sha256 on, as data in node.env, and refuses to render
# a first server that would have nothing to download or nothing to verify with.
# Both inputs default to a pinned kube-platform release.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"
}

run "url_and_hash_reach_node_env" {
  command = plan
  variables {
    argocd_manifest_url    = "https://example.invalid/releases/v1/argocd-bootstrap.yaml"
    argocd_manifest_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "ARGOCD_MANIFEST_URL='https://example.invalid/releases/v1/argocd-bootstrap.yaml'")
      && strcontains(base64decode(f.content), "ARGOCD_MANIFEST_SHA256='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "node.env must carry the Argo CD manifest URL and sha256 for bootstrap.sh"
  }
}

run "defaults_pass_validation_and_reach_node_env" {
  command = plan
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "ARGOCD_MANIFEST_URL='https://github.com/bbaliyan/kube-platform/releases/download/stable-20261108/argocd-bootstrap.yaml'")
      && strcontains(base64decode(f.content), "ARGOCD_MANIFEST_SHA256='e18c81805a4d299e93003c16662b889a05e075cc969a11098e54a4dabceb234d'")
      if f.path == "/opt/kube-compute/node.env"
    ])
    error_message = "with no manifest input, node.env must carry the pinned default URL and sha256"
  }
}

run "first_server_with_gitops_rejects_null_inputs" {
  command = plan
  variables {
    argocd_manifest_url    = null
    argocd_manifest_sha256 = null
  }
  expect_failures = [output.cloud_init_user_data, output.user_data]
}

run "first_server_without_gitops_needs_neither" {
  command = plan
  variables {
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
    argocd_manifest_url       = null
    argocd_manifest_sha256    = null
  }
  assert {
    condition     = output.node_name == "test-cp-0"
    error_message = "a cluster without GitOps must still render without the Argo CD manifest inputs"
  }
}

run "joining_server_needs_neither" {
  command = plan
  variables {
    node_role              = "server-join"
    argocd_manifest_url    = null
    argocd_manifest_sha256 = null
  }
  assert {
    condition     = output.node_name == "test-cp-0"
    error_message = "only the first server downloads the Argo CD manifest"
  }
}

run "short_hash_is_rejected" {
  command = plan
  variables {
    argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
    argocd_manifest_sha256 = "abc123"
  }
  expect_failures = [var.argocd_manifest_sha256]
}

run "uppercase_hash_is_rejected" {
  command = plan
  variables {
    argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
    argocd_manifest_sha256 = "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
  }
  expect_failures = [var.argocd_manifest_sha256]
}

run "non_hex_hash_is_rejected" {
  command = plan
  variables {
    argocd_manifest_url    = "https://example.invalid/argocd-bootstrap.yaml"
    argocd_manifest_sha256 = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
  }
  expect_failures = [var.argocd_manifest_sha256]
}

run "plain_http_url_is_rejected" {
  command = plan
  variables {
    argocd_manifest_url    = "http://example.invalid/argocd-bootstrap.yaml"
    argocd_manifest_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
  expect_failures = [var.argocd_manifest_url]
}
