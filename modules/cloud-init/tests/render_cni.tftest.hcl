# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-al2023.yaml.tpl"
}

run "flannel_is_the_default_no_cni_flags_or_manifest" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "--flannel-backend=none")
    error_message = "cni defaults to flannel; no --flannel-backend=none should render"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "--disable-kube-proxy")
    error_message = "cni defaults to flannel; no --disable-kube-proxy should render"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "kind: HelmChart\n      metadata:\n        name: cilium")
    error_message = "no Cilium HelmChart manifest when cni is flannel"
  }
}

run "cilium_renders_k3s_flags_for_server_init" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
    node_role    = "server-init"
    cni          = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--flannel-backend=none --disable-network-policy --disable-kube-proxy")
    error_message = "cni=cilium must render the flannel-disable/network-policy-disable/kube-proxy-disable flags for server-init"
  }
}

run "cilium_renders_k3s_flags_for_server_join" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+k3s1"
    node_role            = "server-join"
    registration_address = "10.0.0.5"
    cni                  = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "--flannel-backend=none --disable-network-policy --disable-kube-proxy")
    error_message = "cni=cilium must render the same flags identically on server-join (K3s requires flannel options match on every server)"
  }
}

run "cilium_omits_flags_for_worker" {
  command = plan
  variables {
    cluster_name              = "test1"
    k8s_version               = "v1.36.1+k3s1"
    node_role                 = "worker"
    registration_address      = "10.0.0.5"
    agent_token_fetch_command = "echo faketoken"
    cni                       = "cilium"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "--flannel-backend=none")
    error_message = "flannel-backend is a server-only K3s option; a worker's agent install must never carry it"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "kind: HelmChart\n      metadata:\n        name: cilium")
    error_message = "the Cilium HelmChart manifest belongs in K3s's server-only manifests directory; a worker must never write it"
  }
}

run "cilium_manifest_present_and_correct_on_server_init" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
    node_role    = "server-init"
    cni          = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "/var/lib/rancher/k3s/server/manifests/cilium.yaml")
    error_message = "the Cilium HelmChart CR must be written to K3s's own auto-deploy manifests directory, not /etc/kube-compute/manifests (which is only kubectl-applied post-node-Ready, too late for a CNI)"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "repo: https://helm.cilium.io/")
    error_message = "Cilium HelmChart must point at the official chart repo"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "chart: cilium")
    error_message = "Cilium HelmChart must reference the cilium chart"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "version: \"1.19.5\"")
    error_message = "Cilium chart version must be pinned"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "bootstrap: true")
    error_message = "spec.bootstrap must be true — this is what lets K3s's helm-controller install a CNI chart via hostNetwork before any CNI exists"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "k8sServiceHost: \"127.0.0.1\"")
    error_message = "Cilium must reach the apiserver via K3s's own always-present local client load-balancer proxy, not a runtime-templated node IP"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "k8sServicePort: 6444")
    error_message = "6444 is K3s's client load-balancer proxy port, present on every node regardless of role or topology"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "kubeProxyReplacement: true")
    error_message = "Cilium must be told to run in kube-proxy-replacement mode to match --disable-kube-proxy"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "clusterPoolIPv4PodCIDRList: [\"10.42.0.0/16\"]")
    error_message = "Cilium's pod CIDR must match K3s's default pod CIDR"
  }
}

run "cilium_manifest_also_present_on_server_join" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+k3s1"
    node_role            = "server-join"
    registration_address = "10.0.0.5"
    cni                  = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "/var/lib/rancher/k3s/server/manifests/cilium.yaml")
    error_message = "every server (not just server-init) must carry the Cilium manifest — K3s's manifest-directory apply is idempotent per-server, the same way K3s ships its own bundled addons on every server"
  }
}

run "invalid_cni_rejected" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
    cni          = "calico"
  }
  expect_failures = [var.cni]
}
