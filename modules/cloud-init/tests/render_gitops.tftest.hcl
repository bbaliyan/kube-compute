# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-almalinux-10.yaml.tpl"
}

run "root_app_rendered" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    gitops_root_repo_url = "https://github.com/example/kube-apps.git"
    gitops_root_revision = "v1.0.0"
    gitops_root_path     = "test1"
  }
  assert {
    # Rendered at boot via a transient helm binary (render_via_helm), not a
    # static HelmChart CR — see .scratch/cilium-argocd-gitops-handoff/map.md
    # in the kube-claude repo.
    condition     = strcontains(nonsensitive(output.cloud_init), "render_via_helm argocd argo-cd https://argoproj.github.io/argo-helm")
    error_message = "Argo CD genesis render must run when a root repo is set"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "name: root")
    error_message = "genesis must plant a single app-of-apps root Application"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "https://github.com/example/kube-apps.git")
    error_message = "root Application must reference the root repo"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "path: test1")
    error_message = "root Application must use the configured root path"
  }
  assert {
    # valuesObject is rendered via jsonencode (valid YAML); the per-cluster
    # values are threaded under a "platform" key for the root chart to forward
    # to its kube-platform child.
    condition     = strcontains(nonsensitive(output.cloud_init), "\"platform\":")
    error_message = "root Application must thread per-cluster values under a platform key"
  }
}

run "ingress_suffix_is_bare_not_api_fqdn" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    cluster_fqdn         = "api.test1.example.test"
    cluster_fqdn_suffix  = "test1.example.test"
    gitops_root_repo_url = "https://github.com/example/kube-apps.git"
  }
  assert {
    # Guards the bug where clusterFqdnSuffix was fed the api-prefixed API FQDN:
    # the ingress suffix must be the bare suffix so Traefik hosts match the
    # *.<suffix> wildcard, not api.<suffix>.
    condition     = strcontains(nonsensitive(output.cloud_init), "\"clusterFqdnSuffix\":\"test1.example.test\"")
    error_message = "clusterFqdnSuffix must carry the bare ingress suffix, not the api-prefixed API FQDN"
  }
}

run "no_gitops" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
    cni          = "default"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "render_via_helm argocd argo-cd https://argoproj.github.io/argo-helm")
    error_message = "no Argo CD wiring when no root repo is set"
  }
}
