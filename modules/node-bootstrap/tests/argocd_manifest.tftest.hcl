# SPDX-License-Identifier: Apache-2.0
# bootstrap.sh no longer downloads Argo CD. It applies bootstrap/rendered/argocd.yaml
# from the platform ref (see platform_clone.tftest.hcl). The argocd_manifest_url and
# argocd_manifest_sha256 inputs stay for one release so callers do not break; the
# next ticket removes them. These tests lock in that nothing uses them and that
# they still validate until then.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"
}

run "the_inputs_no_longer_reach_node_env_or_the_program" {
  command = plan
  variables {
    argocd_manifest_url    = "https://example.invalid/releases/v1/argocd-bootstrap.yaml"
    argocd_manifest_sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
  assert {
    condition = !anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "example.invalid") || strcontains(base64decode(f.content), "ARGOCD_MANIFEST")
    ])
    error_message = "no payload file may carry the Argo CD manifest URL or sha256 any more"
  }
  assert {
    condition     = !strcontains(local.bootstrap_program, "ARGOCD_MANIFEST") && !strcontains(local.bootstrap_program, "mktemp")
    error_message = "bootstrap.sh must not download the Argo CD manifest"
  }
}

run "first_server_with_gitops_accepts_null_inputs" {
  command = plan
  variables {
    argocd_manifest_url    = null
    argocd_manifest_sha256 = null
  }
  assert {
    condition     = output.node_name == "test-cp-0"
    error_message = "the first server must render without the unused Argo CD manifest inputs"
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
