# SPDX-License-Identifier: Apache-2.0
# Regression test for a real bug hit on a live apply: a caller (a
# *-control-plane module) passing an explicit null (or "") for
# gitops_platform_repo_url/_revision — the normal "no override" case — must
# fall back to the pinned kube-platform coordinates. It does NOT do so for
# free via Terraform's module-argument defaulting (that convenience is
# specific to optional() object-type attributes, not plain string variables
# passed through a module call) — verified the hard way when a literal null
# reached the rendered platform Application manifest. coalesce() in main.tf's
# effective_gitops_platform_repo_url/_revision locals is the actual fix; this
# test locks it in by decoding the rendered cloud-init payload's platform
# Application manifest write_files entry.
#
# cni = "default" throughout so these runs only need the Argo CD genesis
# render (helm-render.py against argo-helm), not the Cilium one too.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  k8s_version         = "v1.36.2+rke2r1"
  node_role           = "server-init"
  cluster_token       = "tok"
  cluster_agent_token = "agenttok"
  cni                 = "default"
}

run "null_repo_url_falls_back_to_the_pin" {
  command = plan
  variables {
    gitops_platform_repo_url = null
    gitops_platform_revision = null
  }
  assert {
    condition = strcontains(
      base64decode(one([
        for f in yamldecode(trimprefix(output.cloud_init_user_data, "#cloud-config\n")).write_files :
        f.content if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
      ])),
      "kube-platform.git",
    )
    error_message = "an explicit null gitops_platform_repo_url must fall back to the pinned kube-platform repo, not resolve to a literal null"
  }
}

run "empty_string_repo_url_also_falls_back_to_the_pin" {
  command = plan
  variables {
    gitops_platform_repo_url = ""
    gitops_platform_revision = ""
  }
  assert {
    condition = strcontains(
      base64decode(one([
        for f in yamldecode(trimprefix(output.cloud_init_user_data, "#cloud-config\n")).write_files :
        f.content if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
      ])),
      "kube-platform.git",
    )
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
    condition = strcontains(
      base64decode(one([
        for f in yamldecode(trimprefix(output.cloud_init_user_data, "#cloud-config\n")).write_files :
        f.content if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
      ])),
      "example.test/fork.git",
    )
    error_message = "an explicit override must still take effect, not be silently replaced by the pin"
  }
  assert {
    condition = !strcontains(
      base64decode(one([
        for f in yamldecode(trimprefix(output.cloud_init_user_data, "#cloud-config\n")).write_files :
        f.content if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
      ])),
      "kube-platform.git",
    )
    error_message = "the pin must not leak through when a real override is set"
  }
}

run "disabled_platform_writes_no_platform_manifest_regardless_of_pin" {
  command = plan
  variables {
    gitops_platform_enabled = false
  }
  assert {
    condition = length([
      for f in yamldecode(trimprefix(output.cloud_init_user_data, "#cloud-config\n")).write_files :
      f.path if f.path == "/opt/kube-compute/manifests/10-platform-app.yaml"
    ]) == 0
    error_message = "gitops_platform_enabled = false must skip the platform Application entirely, even though the pin would otherwise apply"
  }
}
