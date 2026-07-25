# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-almalinux-9.yaml.tpl"
}

run "flannel_is_the_default_no_cni_flags_or_manifest" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "cni: cilium")
    error_message = "cni defaults to the non-cilium value; no cni: cilium key should render, leaving RKE2's own default (Canal) in effect"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "disable-kube-proxy: true")
    error_message = "cni defaults to the non-cilium value; no disable-kube-proxy: true should render"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "kind: HelmChart\n      metadata:\n        name: cilium")
    error_message = "no Cilium HelmChart manifest when cni is not cilium"
  }
}

run "cilium_renders_rke2_config_for_server_init" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
    node_role    = "server-init"
    cni          = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "cni: cilium")
    error_message = "cni=cilium must render the cni: cilium config.yaml key for server-init"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "disable-kube-proxy: true")
    error_message = "cni=cilium must disable RKE2's built-in kube-proxy so Cilium's own replacement takes over"
  }
}

run "cilium_renders_rke2_config_for_server_join" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    node_role            = "server-join"
    registration_address = "10.0.0.5"
    cni                  = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "cni: cilium") && strcontains(nonsensitive(output.cloud_init), "disable-kube-proxy: true")
    error_message = "cni=cilium must render identically on server-join (RKE2 requires CNI/kube-proxy settings match on every server)"
  }
}

run "cilium_omits_flags_for_worker" {
  command = plan
  variables {
    cluster_name              = "test1"
    k8s_version               = "v1.36.1+rke2r1"
    node_role                 = "worker"
    registration_address      = "10.0.0.5"
    agent_token_fetch_command = "echo faketoken"
    cni                       = "cilium"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "cni: cilium")
    error_message = "cni is a server-only RKE2 config key; a worker's agent config.yaml must never carry it"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "kind: HelmChart\n      metadata:\n        name: cilium")
    error_message = "the Cilium HelmChart manifest belongs in RKE2's server-only manifests directory; a worker must never write it"
  }
}

run "cilium_manifest_present_and_correct_on_server_init" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
    node_role    = "server-init"
    cni          = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "/var/lib/rancher/rke2/server/manifests/cilium.yaml")
    error_message = "the Cilium HelmChart CR must be written to RKE2's own auto-deploy manifests directory, not /etc/kube-compute/manifests (which is only kubectl-applied post-node-Ready, too late for a CNI)"
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
    error_message = "spec.bootstrap must be true — this is what lets RKE2's helm-controller install a CNI chart via hostNetwork before any CNI exists"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "k8sServiceHost: \"127.0.0.1\"")
    error_message = "Cilium must reach the apiserver via the local node, not a runtime-templated node IP"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "k8sServicePort: 6443")
    error_message = "6443 is the Kubernetes apiserver port on RKE2 directly — unlike K3s, RKE2 has no combined supervisor+apiserver port-shifting quirk (RKE2's supervisor/join API lives on a separate port, 9345)"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "kubeProxyReplacement: true")
    error_message = "Cilium must be told to run in kube-proxy-replacement mode to match disable-kube-proxy: true"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "clusterPoolIPv4PodCIDRList: [\"10.42.0.0/16\"]")
    error_message = "Cilium's pod CIDR must match RKE2's default pod CIDR"
  }
}

run "cilium_manifest_also_present_on_server_join" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    node_role            = "server-join"
    registration_address = "10.0.0.5"
    cni                  = "cilium"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "/var/lib/rancher/rke2/server/manifests/cilium.yaml")
    error_message = "every server (not just server-init) must carry the Cilium manifest — RKE2's manifest-directory apply is idempotent per-server, the same way RKE2 ships its own bundled addons on every server"
  }
}

run "invalid_cni_rejected" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
    cni          = "calico"
  }
  expect_failures = [var.cni]
}
