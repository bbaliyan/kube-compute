# SPDX-License-Identifier: Apache-2.0
# Regression test for a real bug hit on a live apply: a caller (a
# *-control-plane module) passing an explicit null (or "") for
# gitops_platform_repo_url/_revision — the normal "no override" case — must
# fall back to the pinned kube-platform coordinates. It does NOT do so for
# free via Terraform's module-argument defaulting (that convenience is
# specific to optional() object-type attributes, not plain string variables
# passed through a module call) — verified the hard way when a literal null
# reached Ansible's extra-vars and crashed the `| length > 0` gate. coalesce()
# in main.tf's effective_gitops_platform_repo_url/_revision locals is the
# actual fix; this test locks it in.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
  k8s_version  = "v1.36.2+rke2r1"

  invocation_mode     = "on_node"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"
}

run "null_repo_url_falls_back_to_the_pin" {
  command = plan
  variables {
    gitops_platform_repo_url = null
    gitops_platform_revision = null
  }
  assert {
    condition     = strcontains(output.on_node_bundle, "kube-platform.git")
    error_message = "an explicit null gitops_platform_repo_url must fall back to the pinned kube-platform repo, not resolve to a literal null"
  }
  assert {
    condition     = !strcontains(output.on_node_bundle, "\"gitops_platform_repo_url\":null")
    error_message = "gitops_platform_repo_url must never reach Ansible's extra-vars as a literal null (crashes the `| length > 0` gate)"
  }
  assert {
    condition     = !strcontains(output.on_node_bundle, "\"gitops_platform_revision\":null")
    error_message = "gitops_platform_revision must never reach Ansible's extra-vars as a literal null"
  }
}

run "empty_string_repo_url_also_falls_back_to_the_pin" {
  command = plan
  variables {
    gitops_platform_repo_url = ""
    gitops_platform_revision = ""
  }
  assert {
    condition     = strcontains(output.on_node_bundle, "kube-platform.git")
    error_message = "an explicit empty-string gitops_platform_repo_url must also fall back to the pin (cluster-facts re-exports unset overrides as \"\", not null)"
  }
}

run "explicit_override_still_wins" {
  command = plan
  variables {
    gitops_platform_repo_url = "https://example.test/fork.git"
    gitops_platform_revision = "v9.9.9"
  }
  assert {
    condition     = strcontains(output.on_node_bundle, "example.test/fork.git")
    error_message = "an explicit override must still take effect, not be silently replaced by the pin"
  }
  assert {
    condition     = !strcontains(output.on_node_bundle, "kube-platform.git")
    error_message = "the pin must not leak through when a real override is set"
  }
}

run "disabled_platform_still_gets_no_repo_url_regardless_of_pin" {
  command = plan
  variables {
    gitops_platform_enabled = false
  }
  assert {
    condition     = !strcontains(output.on_node_bundle, "kube-platform.git")
    error_message = "gitops_platform_enabled = false must skip the platform entirely, even though the pin would otherwise apply"
  }
}
