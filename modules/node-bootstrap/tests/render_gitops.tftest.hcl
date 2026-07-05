# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-al2023.yaml.tpl"
}

run "platform_only" {
  command = plan
  variables {
    cluster_name             = "test1"
    k8s_version              = "v1.36.1+k3s1"
    gitops_platform_repo_url = "https://github.com/example/kube-platform.git"
    gitops_platform_revision = "v1.0.0"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "kind: HelmChart")
    error_message = "Argo CD HelmChart must be present when a platform repo is set"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "https://github.com/example/kube-platform.git")
    error_message = "platform Application must reference the platform repo"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "path: bootstrap")
    error_message = "platform Application must use the fixed 'bootstrap' path"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "name: workloadsRepoURL\n                value: \"\"")
    error_message = "workloadsRepoURL helm parameter must be empty when no workloads repo is set"
  }
}

run "platform_and_workloads" {
  command = plan
  variables {
    cluster_name              = "test1"
    k8s_version               = "v1.36.1+k3s1"
    gitops_platform_repo_url  = "https://github.com/example/kube-platform.git"
    gitops_workloads_repo_url = "https://github.com/example/my-apps.git"
    gitops_workloads_path     = "clusters/home"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "name: workloadsRepoURL\n                value: \"https://github.com/example/my-apps.git\"")
    error_message = "workloadsRepoURL helm parameter must carry the configured workloads repo"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "name: workloadsPath\n                value: \"clusters/home\"")
    error_message = "workloadsPath helm parameter must carry the configured workloads path"
  }
}

run "no_gitops" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "kind: HelmChart")
    error_message = "no Argo CD wiring when no platform repo is set"
  }
}
