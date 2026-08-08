# SPDX-License-Identifier: Apache-2.0
# Guards the lean-cloud-init contract: the payload must be a single valid
# cloud-config document, must set a distinct hostname, must carry the runtime
# bootstrap script, and must gate the genesis-only Cilium/Argo CD apply steps
# on node_role == "server-init". This module renders neither manifest itself
# (kube-image bakes both onto the template) — no `helm`/network dependency
# for these tests to mock.

variables {
  cluster_name = "test"
  node_name    = "test-cp-0"
  k8s_version  = "v1.36.2+rke2r1"
}

run "server_init_payload_is_valid_cloud_config" {
  command = plan

  variables {
    node_role                = "server-init"
    cluster_token            = "SUPERSECRETTOKEN123"
    cluster_agent_token      = "SUPERSECRETAGENT456"
    cluster_fqdn             = "api.test.example"
    cluster_fqdn_suffix      = "test.example"
    extra_tls_sans           = ["*.test.example"]
    gitops_platform_repo_url = "https://example.test/platform.git"
  }

  assert {
    condition     = startswith(output.cloud_init_user_data, "#cloud-config\n")
    error_message = "the payload must start with the #cloud-config marker line or cloud-init ignores it entirely"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).hostname == "test-cp-0"
    error_message = "the payload must set the OS hostname — RKE2/kubelet default the registered Kubernetes node name to it, so a missing or colliding hostname silently clobbers another node's registration"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).fqdn == "test-cp-0.test.example"
    error_message = "cluster_fqdn_suffix must produce a matching cloud-init fqdn"
  }
  assert {
    condition     = yamldecode(output.cloud_init_user_data).runcmd == [["/opt/kube-compute/bootstrap.sh"]]
    error_message = "the payload must invoke the bootstrap script from runcmd"
  }
  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/bootstrap.sh"
    )
    error_message = "the payload must deliver the bootstrap script via write_files"
  }
  assert {
    condition = alltrue([
      for f in yamldecode(output.cloud_init_user_data).write_files : f.encoding == "b64"
    ])
    error_message = "every write_files entry must be base64-encoded — that is what keeps an arbitrary PEM, Helm render, or operator-supplied manifest from breaking the outer cloud-config document"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      f.permissions == "0600" if f.path == "/opt/kube-compute/secrets.env"
    ])
    error_message = "secrets.env must be mode 0600 — it carries the cluster join tokens and the TSIG secret"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "\"*.test.example\"")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a wildcard tls-san must be emitted quoted — '*' is YAML's alias indicator, so an unquoted entry is invalid YAML and RKE2 refuses to start"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "secrets-encryption: true") &&
      strcontains(base64decode(f.content), "disable-cloud-controller: true") &&
      strcontains(base64decode(f.content), "ingress-controller: none")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "the ported config.yaml must keep secrets-encryption, disable-cloud-controller, and ingress-controller: none"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "install -m 0600 \"$KC/manifests/cilium.yaml\"")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a server-init node with cni = cilium must install the (kube-image-baked) genesis Cilium manifest into RKE2's auto-deploy directory"
  }
  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/opt/kube-compute/manifests/10-platform-app.yaml"
    )
    error_message = "a server-init node with a platform repo must carry the platform Application manifest"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "kubelet-arg")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "with dns_servers unset, no kubelet-arg resolv-conf override should be emitted at all"
  }
}

# Regression test for a real bug hit on a live apply: kubelet's default
# ClusterFirst DNS policy copies the node's own /etc/resolv.conf search
# domains into every pod. This node's own search domain (NetworkManager-
# derived from its FQDN, cluster_fqdn_suffix) collides with the wildcard
# cluster DNS record for that same zone — with a pod's default ndots:5, a
# bare external hostname like "github.com" gets that search suffix tried
# first, silently resolving to the cluster's own wildcard IP. Confirmed on
# cluster-1: Argo CD's repo-server tried to git-clone github.com against the
# node's own IP over HTTPS and got connection refused.
run "dns_servers_set_gives_kubelet_a_search_domain_free_resolv_conf" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "SUPERSECRETTOKEN123"
    cluster_agent_token       = "SUPERSECRETAGENT456"
    cluster_fqdn              = "api.test.example"
    cluster_fqdn_suffix       = "test.example"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
    dns_servers               = ["1.1.1.1", "9.9.9.9"]
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      base64decode(f.content) == "nameserver 1.1.1.1\nnameserver 9.9.9.9\n"
      if f.path == "/etc/rancher/rke2/resolv-conf-no-search.conf"
    ])
    error_message = "the kubelet resolv-conf override file must contain exactly the given nameservers, no search domain"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "kubelet-arg:") &&
      strcontains(base64decode(f.content), "resolv-conf=/etc/rancher/rke2/resolv-conf-no-search.conf")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "config.yaml must point kubelet at the search-domain-free resolv-conf override"
  }
}

run "worker_payload_skips_genesis_only_content" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
    node_labels               = { "topology.kubernetes.io/zone" = "eu-west-1a" }
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "manifests/cilium.yaml")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a worker must not install the genesis Cilium manifest — Cilium is cluster-wide state applied once by genesis"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "manifests/00-argocd.yaml")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a worker must not apply the Argo CD manifest"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "server: https://10.0.0.10:9345") &&
      strcontains(base64decode(f.content), "topology.kubernetes.io/zone=eu-west-1a")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a worker's config.yaml render must carry its join URL and its node labels"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "systemctl enable --now rke2-agent.service")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a worker must start rke2-agent, never rke2-server — one shared image installs both units and the role picks at launch"
  }
}

run "server_join_uses_the_staggered_self_healing_join" {
  command = plan

  variables {
    node_role            = "server-join"
    node_name            = "test-cp-1"
    registration_address = "10.0.0.10"
    cluster_token        = "SUPERSECRETTOKEN123"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "join-race exhausted after 6 attempts")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a server-join node must keep the self-healing join retry loop — etcd admits one non-voting learner at a time, so a concurrent join must wipe local server state and retry"
  }
  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      !strcontains(base64decode(f.content), "manifests/cilium.yaml")
      if f.path == "/opt/kube-compute/bootstrap.sh"
    ])
    error_message = "a joining server must not re-apply the genesis Cilium manifest"
  }
}

run "registry_mirror_pins_containerd_tls_to_the_trusted_ca" {
  command = plan

  variables {
    node_role                 = "worker"
    node_name                 = "test-worker-0"
    registration_address      = "10.0.0.10"
    agent_token_fetch_command = "echo tok"
    registry_mirror_url       = "https://mirror.test"
    trusted_ca_pem            = "-----BEGIN CERTIFICATE-----\nZHVtbXk=\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      strcontains(base64decode(f.content), "\"mirror.test\":") &&
      strcontains(base64decode(f.content), "ca_file: /etc/pki/ca-trust/source/anchors/trusted-ca.crt")
      if f.path == "/etc/rancher/rke2/registries.yaml"
    ])
    error_message = "registries.yaml must strip the scheme from the mirror host and pin containerd's TLS verification to the trusted CA anchor"
  }
  assert {
    condition = contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/etc/pki/ca-trust/source/anchors/trusted-ca.crt"
    )
    error_message = "trusted_ca_pem must be written to the OS trust anchors directory"
  }
}
