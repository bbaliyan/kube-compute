# SPDX-License-Identifier: Apache-2.0
# node-bootstrap renders a lean cloud-init payload. It executes NOTHING: no
# null_resource, no local-exec, no Ansible, no connection to the node. The
# heavy half of RKE2 bootstrap (OS prep, RKE2 binaries, SELinux policy, kernel
# modules, guest agent) is baked into a kube-image template; what's left here
# is per-cluster identity, secrets, and join logic — what can't be baked into
# a shared image.
locals {
  # Single source of truth for the kube-platform pin, held directly here — this
  # is node-bootstrap's only remaining consumer, so a separate component-versions
  # module was pure indirection. NOT the gitops_platform_repo_url/_revision
  # variables' own defaults: an explicit null/"" passed through a module call
  # does NOT fall through to the callee's variable default the way an omitted
  # argument would (that convenience is specific to optional() object-type
  # attributes) — verified the hard way on a real apply; the regression test
  # in tests/platform_pin.tftest.hcl locks it in. coalesce() is the fix, since
  # it treats null and "" identically. Tracks kube-platform's protected `main`
  # branch, not a pinned SHA — branch protection is the safeguard replacing
  # the reproducibility a SHA pin would give.
  pinned_platform_repo_url = "https://github.com/bbaliyan/kube-platform.git"
  pinned_platform_revision = "main"

  # gitops_platform_enabled = false clears the repo URL to "" regardless of the
  # pin, so every gate downstream can keep testing "repo_url non-empty" as the
  # single signal, matching gitops_workloads_repo_url's null-means-skip shape.
  effective_gitops_platform_repo_url = var.gitops_platform_enabled ? coalesce(var.gitops_platform_repo_url, local.pinned_platform_repo_url) : ""
  effective_gitops_platform_revision = coalesce(var.gitops_platform_revision, local.pinned_platform_revision)

  effective_gitops_workloads_repo_url = var.gitops_workloads_repo_url != null ? var.gitops_workloads_repo_url : ""

  platform_app_enabled  = local.effective_gitops_platform_repo_url != ""
  workloads_app_enabled = local.effective_gitops_workloads_repo_url != ""
  # Argo CD itself is only needed when at least one of the two Applications is
  # going to be applied — a non-empty sentinel covers both.
  argocd_needed = local.platform_app_enabled || local.workloads_app_enabled

  # nsupdate's `zone` directive requires a fully-qualified (trailing-dot) name,
  # but callers commonly pass a bare zone (e.g. "lan"). Normalize here so
  # either form works identically, mirroring proxmox-control-plane's own
  # local.dns_zone. Idempotent; both null and "" stay "" so the
  # no-self-registration path is unaffected.
  dns_self_register_zone = var.dns_self_register_zone != null && var.dns_self_register_zone != "" ? "${trimsuffix(var.dns_self_register_zone, ".")}." : ""

  # nsupdate transport flags, derived exactly as the Ansible role derived them:
  # -v forces TCP, -4/-6 pin the address family.
  nsupdate_flags = trimspace(join(" ", compact([
    startswith(var.dns_transport, "tcp") ? "-v" : "",
    endswith(var.dns_transport, "4") ? "-4" : "",
    endswith(var.dns_transport, "6") ? "-6" : "",
  ])))

  is_server = contains(["server-init", "server-join"], var.node_role)

  # Whether bootstrap.sh should apply the Cilium/Argo CD manifests kube-image
  # already baked onto every template at /opt/kube-compute/manifests/ — a
  # per-cluster runtime decision (CNI choice, GitOps enablement), independent
  # of whether the files exist on disk (they always do). This module renders
  # neither: the live `helm template` render that used to happen here exceeded
  # Proxmox's 1 MiB cicustom snippet cap on a real apply — see kube-image's
  # packer/proxmox/build.sh and helm-values/ for where the render moved.
  render_cilium = var.cni == "cilium" && var.node_role == "server-init"
  render_argocd = local.argocd_needed && var.node_role == "server-init"

  # Genesis-only, same as render_cilium/render_argocd — but deliberately NOT
  # gated on argocd_needed/render_argocd: an arbitrary genesis-apply manifest
  # (e.g. proxmox-cluster's CAPI/CAPMOX cluster-autoscaler bundle) is applied
  # by bootstrap.sh as a one-time genesis step, independent of whether this
  # cluster also runs a platform or workloads Argo CD Application. Tying it to
  # render_argocd would mean gitops_platform_enabled = false callers never get
  # the write_files entries bootstrap.sh's apply step expects. This module
  # does not render or interpret genesis_apply_manifests' content — that
  # happens in the composing module (e.g. proxmox-cluster), which has access
  # to inputs (like module.control_plane's outputs) this leaf module does not.
  effective_genesis_apply_manifests = var.node_role == "server-init" ? var.genesis_apply_manifests : []
  effective_crd_wait_enabled        = var.node_role == "server-init" && var.cluster_autoscaler_crd_wait_enabled
  genesis_apply_manifest_paths      = [for m in local.effective_genesis_apply_manifests : m.path]

  # Rendered by templatefile()/yamlencode() here, not on the node — keeps the
  # node free of any templating engine.
  platform_values_object = merge(
    var.platform_helm_values_object != null ? var.platform_helm_values_object : {},
    { extraTags = var.extra_tags },
  )

  # kube-platform's bootstrap chart reads a clusterAutoscalerEnabled Helm
  # value to decide whether to deploy the cluster-autoscaler Argo CD
  # Application (bootstrap/templates/cluster-autoscaler-app.yaml). This
  # module doesn't own that decision (proxmox-cluster does), so it's not a
  # hardcoded parameter here — the composing module passes it through the
  # generic platform_extra_helm_parameters map instead. Omitting it falls
  # back to kube-platform's own chart default (false).
  #
  # Multi-source Application: the second source (ref: values, no chart)
  # makes platform-versions/values.yaml available to the first source's
  # `helm.valueFiles`, so bootstrap's chart templates (cilium-app.yaml,
  # argocd-app.yaml) can read .Values.ciliumVersion/.Values.argocdVersion at
  # every sync — same mechanism system-upgrade-plans-app.yaml uses for
  # .Values.k8sVersion. This is what makes bumping platform-versions/values.yaml
  # alone enough to roll Cilium/Argo CD forward kube-platform-wide, with no
  # per-cluster apply and no editing the Application templates themselves.
  platform_app_yaml = <<-EOT
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: platform
      namespace: argocd
    spec:
      project: default
      sources:
        - repoURL: ${local.effective_gitops_platform_repo_url}
          targetRevision: ${local.effective_gitops_platform_revision}
          path: bootstrap
          helm:
            valueFiles:
              - $values/platform/platform-versions/values.yaml
            parameters:
              - name: platformRepoURL
                value: "${local.effective_gitops_platform_repo_url}"
              - name: platformRevision
                value: "${local.effective_gitops_platform_revision}"
              - name: certMode
                value: "${var.cert_mode}"
              - name: clusterName
                value: "${var.cluster_name}"
              - name: clusterFqdnSuffix
                value: "${var.cluster_fqdn_suffix != null ? var.cluster_fqdn_suffix : ""}"
              - name: trustedCaPemB64
                value: "${base64encode(var.trusted_ca_pem != null ? var.trusted_ca_pem : "")}"
    %{~for name, val in var.platform_extra_helm_parameters~}
              - name: ${name}
                value: "${val}"
    %{~endfor~}
            valuesObject:
              ${indent(14, yamlencode(local.platform_values_object))}
        - repoURL: ${local.effective_gitops_platform_repo_url}
          targetRevision: ${local.effective_gitops_platform_revision}
          ref: values
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: ["CreateNamespace=true"]
  EOT

  # Deliberately independent of the platform Application: no shared app-of-apps
  # parent, no sync-wave ordering against it. Eventual consistency — if a
  # workload needs something platform provides, Argo CD's own automated
  # selfHeal/retry converges it once platform catches up.
  workloads_app_yaml = <<-EOT
    apiVersion: argoproj.io/v1alpha1
    kind: Application
    metadata:
      name: workloads
      namespace: argocd
    spec:
      project: default
      source:
        repoURL: ${local.effective_gitops_workloads_repo_url}
        targetRevision: ${var.gitops_workloads_revision}
        path: ${var.gitops_workloads_path}
    %{~if length(var.workloads_extra_helm_parameters) > 0~}
        helm:
          parameters:
    %{~for name, val in var.workloads_extra_helm_parameters~}
            - name: ${name}
              value: "${val}"
    %{~endfor~}
    %{~endif~}
      destination:
        server: https://kubernetes.default.svc
        namespace: argocd
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: ["CreateNamespace=true"]
  EOT

  # Ported from registries.yaml.j2, including the containerd TLS pin to the
  # same anchors path the trusted CA is written to.
  registry_mirror_host = var.registry_mirror_url != null ? replace(var.registry_mirror_url, "/^https?:\\/\\//", "") : ""

  registries_yaml = var.registry_mirror_url == null ? "" : join("\n", concat([
    "mirrors:",
    "  docker.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    "  ghcr.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    "  quay.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    "  registry.k8s.io:",
    "    endpoint: [\"${var.registry_mirror_url}\"]",
    ], var.trusted_ca_pem == null ? [] : [
    "configs:",
    "  \"${local.registry_mirror_host}\":",
    "    tls:",
    "      ca_file: /etc/pki/ca-trust/source/anchors/trusted-ca.crt",
  ], [""]))

  # Everything in config.yaml known at plan time. Node-discovered parts
  # (node-ip, its own IP as the first tls-san, the fetched agent token, the
  # rejoin-probe result) are appended by bootstrap.sh on the node itself.
  # Every SAN is quoted: a wildcard entry starts with '*', YAML's alias
  # indicator, so an unquoted "- *.foo" is invalid YAML and RKE2 refuses to
  # start. Quoting is inert for plain IPs/hostnames.
  static_tls_san_block = join("\n", [
    for san in compact(concat([var.cluster_fqdn != null ? var.cluster_fqdn : ""], var.extra_tls_sans)) :
    "  - \"${san}\""
  ])

  server_static_block = join("\n", concat([
    "write-kubeconfig-mode: \"0644\"",
    "secrets-encryption: true",
    "disable-cloud-controller: true",
    # Disables whatever RKE2's default ingress controller is for the installed
    # version (ingress-nginx or Traefik) — this project doesn't bundle one at
    # bootstrap.
    "ingress-controller: none",
    # RKE2 does not expose etcd's Prometheus metrics endpoint (a separate port,
    # 2381, distinct from etcd's client port 2379) unless explicitly told to.
    # Without this, kube-platform's kube-prometheus-stack has nothing to scrape
    # on 2381 regardless of its own ServiceMonitor config. Safe unconditionally:
    # it only exposes a metrics endpoint, it doesn't change etcd's behavior, and
    # etcd only runs on server nodes anyway.
    "etcd-expose-metrics: true",
    ], var.control_plane_taint ? [
    "node-taint:",
    "  - \"CriticalAddonsOnly=true:NoExecute\"",
    ] : [], var.cni == "cilium" ? [
    "cni: cilium",
    "disable-kube-proxy: true",
    # Without this, RKE2 installs its own bundled rke2-cilium addon (a separate
    # HelmChart CR) alongside the genesis-rendered Cilium manifest — both
    # fighting over the same cilium-operator/cilium objects in kube-system.
    "disable:",
    "  - rke2-cilium",
  ] : []))

  node_label_block = length(var.node_labels) == 0 ? "" : join("\n", concat(
    ["node-label:"],
    [for k, v in var.node_labels : "  - \"${k}=${v}\""],
  ))

  # kubelet's default ClusterFirst DNS policy copies the NODE's own
  # /etc/resolv.conf search domains into every pod. NetworkManager derives a
  # search domain from this node's FQDN hostname (cluster_fqdn_suffix) — the
  # same zone a wildcard cluster DNS record (*.<cluster>.<domain>) answers
  # for. With the pod's default ndots:5, a bare external hostname like
  # "github.com" gets that search suffix tried FIRST, silently resolving to
  # the cluster's own wildcard IP instead of the real host — confirmed on a
  # real cluster-1 apply: Argo CD's repo-server tried to git-clone github.com
  # against the node's own IP over HTTPS and got connection refused. Pointing
  # kubelet at a search-domain-free resolv.conf (var.dns_servers only, no
  # `search` line) fixes every pod on the node, without touching the node's
  # own OS resolv.conf (kept search-enabled for host-level convenience).
  # Opt-in via var.dns_servers so a caller that doesn't pass it keeps the old
  # behavior rather than erroring.
  kubelet_resolv_conf_enabled = var.dns_servers != null && length(var.dns_servers) > 0
  kubelet_resolv_conf_path    = "/etc/rancher/rke2/resolv-conf-no-search.conf"
  kubelet_resolv_conf_content = join("\n", concat(
    [for ip in coalesce(var.dns_servers, []) : "nameserver ${ip}"],
    [""],
  ))
  # Applies to every role (server-init, server-join, worker) — kubelet runs
  # on all three and pollutes every pod scheduled to that node identically.
  kubelet_resolv_conf_block = !local.kubelet_resolv_conf_enabled ? "" : join("\n", [
    "kubelet-arg:",
    "  - \"resolv-conf=${local.kubelet_resolv_conf_path}\"",
  ])

  bootstrap_sh = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    node_role                           = var.node_role
    cni                                 = var.cni
    registration_address                = var.registration_address != null ? var.registration_address : ""
    trusted_ca_enabled                  = var.trusted_ca_pem != null
    registry_mirror_url                 = var.registry_mirror_url != null ? var.registry_mirror_url : ""
    dns_self_register_zone              = local.dns_self_register_zone
    dns_self_register_record_name       = var.dns_self_register_record_name != null ? var.dns_self_register_record_name : ""
    dns_self_register_ttl               = var.dns_self_register_ttl
    dns_server_address                  = var.dns_server_address != null ? var.dns_server_address : ""
    dns_server_port                     = var.dns_server_port
    nsupdate_flags                      = local.nsupdate_flags
    tsig_key_name                       = var.tsig_key_name != null ? var.tsig_key_name : ""
    tsig_key_algorithm                  = var.tsig_key_algorithm
    node_label_block                    = local.node_label_block
    static_tls_san_block                = local.static_tls_san_block
    server_static_block                 = local.server_static_block
    kubelet_resolv_conf_block           = local.kubelet_resolv_conf_block
    argocd_needed                       = local.render_argocd
    platform_app_enabled                = local.platform_app_enabled
    workloads_app_enabled               = local.workloads_app_enabled
    cluster_autoscaler_crd_wait_enabled = local.effective_crd_wait_enabled
    genesis_apply_manifest_paths        = local.genesis_apply_manifest_paths
  })

  # Every key is always defined (empty where a role doesn't use it) so
  # bootstrap.sh can run under `set -u` after sourcing it. Single-quoted with
  # the POSIX '\'' escape so any character in a token is safe to embed.
  secret_values = {
    CLUSTER_TOKEN             = var.node_role != "worker" && var.cluster_token != null ? var.cluster_token : ""
    CLUSTER_AGENT_TOKEN       = var.node_role == "server-init" && var.cluster_agent_token != null ? var.cluster_agent_token : ""
    AGENT_TOKEN_FETCH_COMMAND = var.node_role == "worker" && var.agent_token_fetch_command != null ? var.agent_token_fetch_command : ""
    TSIG_KEY_SECRET           = var.tsig_key_secret != null ? var.tsig_key_secret : ""
  }

  secrets_env = join("\n", concat(
    ["# SPDX-License-Identifier: Apache-2.0"],
    [for k in sort(keys(local.secret_values)) : "${k}='${replace(local.secret_values[k], "'", "'\\''")}'"],
    [""],
  ))

  # Every entry is base64-encoded (encoding: b64) — not cosmetic: it makes the
  # outer cloud-config document immune to its own payloads (a PEM, an
  # operator-supplied manifest, a token containing a colon can never break
  # the surrounding YAML), and lets the whole document be safely produced by
  # yamlencode() rather than a text template. Cilium/Argo CD's own manifests
  # are NOT among these entries — kube-image bakes them directly onto the
  # template at /opt/kube-compute/manifests/, and bootstrap.sh reads them
  # from there; embedding Argo CD's ~1.9 MB chart render here is exactly what
  # used to exceed Proxmox's 1 MiB cicustom snippet cap.
  write_files = concat(
    [
      {
        path        = "/opt/kube-compute/secrets.env"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.secrets_env)
      },
      {
        path        = "/opt/kube-compute/bootstrap.sh"
        permissions = "0700"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(local.bootstrap_sh)
      },
    ],
    var.trusted_ca_pem == null ? [] : [{
      path        = "/etc/pki/ca-trust/source/anchors/trusted-ca.crt"
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(var.trusted_ca_pem)
    }],
    var.registry_mirror_url == null ? [] : [{
      path        = "/etc/rancher/rke2/registries.yaml"
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.registries_yaml)
    }],
    !local.kubelet_resolv_conf_enabled ? [] : [{
      path        = local.kubelet_resolv_conf_path
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.kubelet_resolv_conf_content)
    }],
    !(local.render_argocd && local.platform_app_enabled) ? [] : [{
      path        = "/opt/kube-compute/manifests/10-platform-app.yaml"
      permissions = "0600"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.platform_app_yaml)
    }],
    !(local.render_argocd && local.workloads_app_enabled) ? [] : [{
      path        = "/opt/kube-compute/manifests/11-workloads-app.yaml"
      permissions = "0644"
      owner       = "root:root"
      encoding    = "b64"
      content     = base64encode(local.workloads_app_yaml)
    }],
    [
      for m in local.effective_genesis_apply_manifests : {
        path        = m.path
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(m.content)
      }
    ],
    !local.is_server ? [] : [
      for name in sort(keys(var.extra_server_manifests)) : {
        path        = "/opt/kube-compute/server-manifests/${name}"
        permissions = "0600"
        owner       = "root:root"
        encoding    = "b64"
        content     = base64encode(var.extra_server_manifests[name])
      }
    ],
  )

  # RKE2/kubelet default the registered Kubernetes node name to the OS
  # hostname, so every node in a cluster MUST get a distinct value here.
  # var.set_hostname = false omits both keys entirely (see that variable's
  # description) — needed only when this same rendered payload is shared
  # across multiple VMs, e.g. a CAPI MachineDeployment's replicas.
  cloud_config = merge(
    {
      preserve_hostname = false
      # RHEL-family distros (this project's only supported OS) default
      # cloud-init's prefer_fqdn to true, which silently applies the fqdn
      # value below as the actual system hostname even when a distinct
      # short hostname is also given — see Distro._select_hostname in
      # cloud-init's own source. An FQDN-formatted static hostname is
      # exactly what NetworkManager derives its DNS search-domain entry
      # from, which then collides with a wildcard cluster DNS record for
      # that same zone (see kubelet_resolv_conf_block's own comment above
      # for the full failure mode). Forcing the short hostname to win here
      # avoids the collision at its source, for every pod on the node, not
      # just kubelet's.
      prefer_fqdn_over_hostname = false
      write_files               = local.write_files
      runcmd                    = [["/opt/kube-compute/bootstrap.sh"]]
    },
    var.set_hostname ? { hostname = var.node_name } : {},
    var.set_hostname && var.cluster_fqdn_suffix != null && var.cluster_fqdn_suffix != "" ? {
      fqdn = "${coalesce(var.node_fqdn_label, var.node_name)}.${var.cluster_fqdn_suffix}"
    } : {},
  )

  # "#cloud-config" is a YAML comment, so the whole document — including this
  # required first line — round-trips through any YAML parser unchanged.
  cloud_init_user_data = "#cloud-config\n${yamlencode(local.cloud_config)}"
}
