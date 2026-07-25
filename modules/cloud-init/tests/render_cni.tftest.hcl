# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-almalinux-10.yaml.tpl"
}

run "cilium_is_the_default" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
    node_role    = "server-init"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "cni: cilium")
    error_message = "cni defaults to cilium — Canal/flannel's iptables/ipset dataplane is broken on AlmaLinux 10, this project's only supported OS"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "disable-kube-proxy: true")
    error_message = "cni defaults to cilium, which must disable RKE2's built-in kube-proxy"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "render_via_helm cilium cilium https://helm.cilium.io/")
    error_message = "the Cilium genesis render must run by default"
  }
}

run "default_cni_opts_out_of_cilium" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+rke2r1"
    cni          = "default"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "cni: cilium")
    error_message = "cni = \"default\" is the escape hatch for a consumer-supplied playbook targeting a different OS; no cni: cilium key should render"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "disable-kube-proxy: true")
    error_message = "cni = \"default\" must not render disable-kube-proxy: true"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "render_via_helm cilium cilium https://helm.cilium.io/")
    error_message = "no Cilium genesis render when cni = \"default\""
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
    condition     = !strcontains(nonsensitive(output.cloud_init), "render_via_helm cilium cilium https://helm.cilium.io/")
    error_message = "the Cilium genesis render belongs to server-init only; a worker must never run it"
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
  # Rendered at boot via a transient helm binary (render_via_helm), not a
  # static HelmChart CR — see .scratch/cilium-argocd-gitops-handoff/map.md in
  # the kube-claude repo. These assertions check the render invocation and
  # its values file, not literal spec.* YAML keys (those only exist in the
  # real rendered output produced on the node at boot, not in this
  # template's own static content).
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "render_via_helm cilium cilium https://helm.cilium.io/ \"1.19.5\" kube-system \"$CILIUM_VALUES\" >/var/lib/rancher/rke2/server/manifests/cilium.yaml")
    error_message = "Cilium must be rendered via helm template and written to RKE2's own auto-deploy manifests directory (not /etc/kube-compute/manifests, which is only kubectl-applied post-node-Ready, too late for a CNI), with its version pinned"
  }
  # The values file is passed as a single base64 line (not a literal
  # heredoc) — see the comment on cloud-init's own cilium_values_yaml local
  # for why. Decode it here to check the actual rendered content, the same
  # way the node would.
  assert {
    condition = strcontains(
      base64decode(regex("echo \"([A-Za-z0-9+/=]+)\" \\| base64 -d >\"\\$CILIUM_VALUES\"", nonsensitive(output.cloud_init))[0]),
      "k8sServiceHost: \"127.0.0.1\""
    )
    error_message = "Cilium must reach the apiserver via the local node, not a runtime-templated node IP"
  }
  assert {
    condition = strcontains(
      base64decode(regex("echo \"([A-Za-z0-9+/=]+)\" \\| base64 -d >\"\\$CILIUM_VALUES\"", nonsensitive(output.cloud_init))[0]),
      "k8sServicePort: 6443"
    )
    error_message = "6443 is the Kubernetes apiserver port on RKE2 directly — unlike K3s, RKE2 has no combined supervisor+apiserver port-shifting quirk (RKE2's supervisor/join API lives on a separate port, 9345)"
  }
  assert {
    condition = strcontains(
      base64decode(regex("echo \"([A-Za-z0-9+/=]+)\" \\| base64 -d >\"\\$CILIUM_VALUES\"", nonsensitive(output.cloud_init))[0]),
      "kubeProxyReplacement: true"
    )
    error_message = "Cilium must be told to run in kube-proxy-replacement mode to match disable-kube-proxy: true"
  }
  assert {
    condition = strcontains(
      base64decode(regex("echo \"([A-Za-z0-9+/=]+)\" \\| base64 -d >\"\\$CILIUM_VALUES\"", nonsensitive(output.cloud_init))[0]),
      "clusterPoolIPv4PodCIDRList: [\"10.42.0.0/16\"]"
    )
    error_message = "Cilium's pod CIDR must match RKE2's default pod CIDR"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "disable:\n        - rke2-cilium")
    error_message = "RKE2's own bundled rke2-cilium addon must be disabled, or it fights the genesis-rendered Cilium manifest over the same objects"
  }
}

run "cilium_manifest_not_re_rendered_on_server_join" {
  command = plan
  variables {
    cluster_name         = "test1"
    k8s_version          = "v1.36.1+rke2r1"
    node_role            = "server-join"
    registration_address = "10.0.0.5"
    cni                  = "cilium"
  }
  assert {
    # Genesis-only (Ticket 04 of .scratch/cilium-argocd-gitops-handoff/map.md):
    # Cilium is a cluster-wide DaemonSet/Deployment, not per-node state — a
    # joining server doesn't need it re-rendered, it just needs the cluster
    # to already have it.
    condition     = !strcontains(nonsensitive(output.cloud_init), "render_via_helm cilium cilium https://helm.cilium.io/")
    error_message = "server-join must not re-render the Cilium manifest — only server-init (genesis) does"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "disable:\n        - rke2-cilium")
    error_message = "server-join still needs disable: [rke2-cilium] in its own config.yaml, independent of who renders the manifest — it stops this node's own RKE2 supervisor from installing the bundled addon"
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
