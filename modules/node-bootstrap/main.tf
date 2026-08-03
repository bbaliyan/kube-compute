# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  playbook_path = coalesce(var.ansible_playbook_path, "${path.module}/ansible/playbook.yml")

  # Resolve to the platform default rather than passing null through: a null/empty
  # version renders "version: \"\"" into the Cilium HelmChart CR, which Helm/RKE2
  # silently treats as "latest".
  cilium_version = coalesce(var.cilium_version, module.component_versions.cilium_version)
  argocd_version = coalesce(var.argocd_version, module.component_versions.argocd_version)

  # Single source of truth for the kube-platform pin is component-versions
  # (shared with cluster-facts, which needs the same pin for its own
  # k8s_version-from-platform-versions.yaml fetch) — NOT the
  # gitops_platform_repo_url/_revision variables' own defaults: a caller (a
  # *-control-plane module) passing an explicit null/"" to override-back-to-
  # the-pin does NOT fall through to a variable's own default the way an
  # omitted argument would — that "explicit null uses the callee's default"
  # convenience is specific to optional() object-type attributes, not plain
  # string variables passed through a module call. Verified the hard way: a
  # real apply, and a regression test below, both showed a literal null reaching
  # Ansible's extra-vars (crashing the `| length > 0` gate) instead of the pin.
  # coalesce() is the actual fix — it treats both null and "" as "not set" uniformly.
  # Tracks kube-platform's protected `main` branch (required PR review before merge),
  # not a pinned commit SHA. This trades "a freshly-provisioned node always bootstraps
  # against a fixed, previously-audited commit" for "platform components — including
  # RKE2 version, via platform/platform-versions/values.yaml — stay continuously
  # current without a terragrunt apply per change." Branch protection is the safeguard
  # replacing the reproducibility guarantee the SHA pin used to provide.
  pinned_platform_repo_url = module.component_versions.pinned_platform_repo_url
  pinned_platform_revision = module.component_versions.pinned_platform_revision

  # gitops_platform_enabled = false clears the repo URL to "" regardless of the pin,
  # so every gate downstream (this module's own tasks, plus the bootstrap-runner
  # template's Argo CD render) can keep testing "repo_url non-empty" as the single
  # signal, matching gitops_workloads_repo_url's existing null-means-skip shape.
  effective_gitops_platform_repo_url = var.gitops_platform_enabled ? coalesce(var.gitops_platform_repo_url, local.pinned_platform_repo_url) : ""
  effective_gitops_platform_revision = coalesce(var.gitops_platform_revision, local.pinned_platform_revision)

  # nsupdate's `zone` directive requires a fully-qualified (trailing-dot) name, but
  # callers commonly pass a bare zone (e.g. "lan") the way they would to any other
  # DNS tool. Normalize here so either form works identically, mirroring the same
  # precedent in proxmox-control-plane/main.tf's local.dns_zone. Idempotent whether
  # or not var.dns_self_register_zone already ends in a dot; both null and "" stay
  # "" so the "no self-registration" no-op path is unaffected either way (the
  # Ansible gate below checks dns_self_register_zone != "").
  dns_self_register_zone = var.dns_self_register_zone != null && var.dns_self_register_zone != "" ? "${trimsuffix(var.dns_self_register_zone, ".")}." : ""

  # Cilium/Argo CD genesis values, computed as plain Terraform strings and
  # base64-encoded into the runner (decoded with a single `base64 -d`) rather than
  # embedded as a nested bash heredoc, which proved fragile inside the runner's own
  # heredoc. `%{ if ~}` here is evaluated by Terraform, not bash.
  cilium_values_yaml = <<-EOT
    kubeProxyReplacement: true
    k8sServiceHost: "127.0.0.1"
    k8sServicePort: 6443
    # Node IPAM LB is the platform's LoadBalancer mechanism on every provider:
    # it advertises the node's own (LAN- or VPC-routable) IP into a
    # LoadBalancer Service, with the eBPF datapath forwarding to pods — no ARP,
    # BGP, cloud API, or extra component. defaultLBServiceIPAM makes every
    # LoadBalancer Service use it without a per-Service loadBalancerClass. Kept
    # in sync with bootstrap/templates/cilium-app.yaml in kube-platform, which
    # is authoritative once Argo CD adopts this genesis install.
    nodeIPAM:
      enabled: true
    defaultLBServiceIPAM: nodeipam
    operator:
    %{~if var.cilium_operator_replicas != null~}
      replicas: ${var.cilium_operator_replicas}
    %{~endif~}
      tolerations:
        - operator: Exists
    ipam:
      operator:
        clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"]
  EOT

  # repoServer/controller resources + probe timeouts: upstream defaults are zero
  # requests (BestEffort QoS) and a 1s probe timeout, which crash-loop Argo CD
  # under a real platform tree. Kept in sync with bootstrap/templates/argocd-app.yaml
  # in kube-platform.
  argocd_values_yaml = <<-EOT
    configs:
      params:
        server.insecure: "true"
    repoServer:
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          cpu: 500m
          memory: 512Mi
      readinessProbe:
        timeoutSeconds: 5
        failureThreshold: 5
      livenessProbe:
        timeoutSeconds: 5
        failureThreshold: 5
    controller:
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
        limits:
          cpu: 1000m
          memory: 1Gi
      readinessProbe:
        timeoutSeconds: 5
        failureThreshold: 5
  EOT

  # Bundled alongside this module's own playbook/roles, not the (possibly
  # overridden) playbook_path — these pin the connection-plugin dependencies
  # this module's operator_connect transports need (amazon.aws + boto3 for AWS
  # SSM), independent of which playbook content a caller substitutes. Not used
  # in on_node mode, which needs no connection plugin (-c local).
  ansible_requirements_yml = "${path.module}/ansible/requirements.yml"
  ansible_requirements_txt = "${path.module}/ansible/requirements.txt"

  # Non-secret extra-vars only. Secrets (cluster_token, cluster_agent_token,
  # agent_token_fetch_command, trusted_ca_pem) are excluded here — they flow
  # through the local-exec `environment` block (operator_connect) or run-command
  # protected parameters (on_node), never the bundle.
  extra_vars = merge(var.ansible_connection_vars, {
    node_provider                  = var.node_provider
    cluster_name                   = var.cluster_name
    node_name                      = var.node_name
    k8s_version                    = var.k8s_version
    cluster_fqdn                   = var.cluster_fqdn != null ? var.cluster_fqdn : ""
    cluster_fqdn_suffix            = var.cluster_fqdn_suffix != null ? var.cluster_fqdn_suffix : ""
    node_role                      = var.node_role
    control_plane_taint            = var.control_plane_taint
    registration_address           = var.registration_address != null ? var.registration_address : ""
    extra_tls_sans                 = var.extra_tls_sans
    cni                            = var.cni
    cilium_version                 = local.cilium_version
    cilium_operator_replicas       = var.cilium_operator_replicas != null ? var.cilium_operator_replicas : 0
    registry_mirror_url            = var.registry_mirror_url != null ? var.registry_mirror_url : ""
    node_labels                    = var.node_labels
    extra_server_manifests         = var.extra_server_manifests
    gitops_platform_repo_url       = local.effective_gitops_platform_repo_url
    argocd_version                 = local.argocd_version
    gitops_platform_revision       = local.effective_gitops_platform_revision
    gitops_workloads_repo_url      = var.gitops_workloads_repo_url != null ? var.gitops_workloads_repo_url : ""
    gitops_workloads_revision      = var.gitops_workloads_revision
    gitops_workloads_path          = var.gitops_workloads_path
    cert_mode                      = var.cert_mode
    platform_extra_helm_parameters = var.platform_extra_helm_parameters
    platform_helm_values_object    = var.platform_helm_values_object != null ? var.platform_helm_values_object : {}
    extra_tags                     = var.extra_tags
    dns_self_register_zone         = local.dns_self_register_zone
    dns_self_register_record_name  = var.dns_self_register_record_name != null ? var.dns_self_register_record_name : ""
    dns_self_register_ttl          = var.dns_self_register_ttl
    dns_server_address             = var.dns_server_address != null ? var.dns_server_address : ""
    dns_server_port                = var.dns_server_port
    dns_transport                  = var.dns_transport
    tsig_key_name                  = var.tsig_key_name != null ? var.tsig_key_name : ""
    tsig_key_algorithm             = var.tsig_key_algorithm
  })

  extra_vars_json = jsonencode(local.extra_vars)

  # Secrets, keyed by node_role so the key SET is known at plan time. This
  # encodes the same role->secret policy every provider module already follows:
  # server-init gets both tokens, server-join the cluster token, worker the fetch
  # command; trusted_ca_pem (a plain input) is added for any role. Role-gating
  # rather than value-presence-gating is deliberate: on_node's caller builds one
  # run-command protected_parameter per key via for_each, which Terraform
  # requires to be plan-known — but the token VALUES come from a random_password
  # and are unknown until apply, so gating the key set on `!= null` would make
  # for_each unknown and fail. node_role and trusted_ca_pem are plain inputs,
  # known at plan. In operator_connect these are the local-exec `environment`;
  # in on_node the caller maps them to run-command protected parameters (exposed
  # via the on_node_secret_env output). Never a file, never an extra-var.
  secret_env = merge(
    var.node_role == "server-init" ? { CLUSTER_TOKEN = var.cluster_token, CLUSTER_AGENT_TOKEN = var.cluster_agent_token } : {},
    var.node_role == "server-join" ? { CLUSTER_TOKEN = var.cluster_token } : {},
    var.node_role == "worker" ? { AGENT_TOKEN_FETCH_COMMAND = var.agent_token_fetch_command } : {},
    var.trusted_ca_pem != null ? { TRUSTED_CA_PEM = var.trusted_ca_pem } : {},
    var.tsig_key_secret != null ? { TSIG_KEY_SECRET = var.tsig_key_secret } : {},
  )

  is_operator_connect = var.invocation_mode == "operator_connect"

  # One template renders the runner for both modes; the Cilium/Argo render and
  # the extra-vars payload are shared, so they can never diverge again (the
  # divergence that motivated retiring the separate cloud-init template). All
  # keys are always present — empty where a mode doesn't use them — so
  # templatefile() never fails on a missing key inside a not-taken branch.
  runner_vars = {
    mode      = var.invocation_mode
    node_name = var.node_name
    cni       = var.cni
    node_role = var.node_role
    # Gates the bootstrap-runner template's Argo CD helm-template render — needed
    # if either the platform or the workloads Application is going to be applied,
    # not just platform, so a non-empty sentinel covers both.
    argocd_needed           = local.effective_gitops_platform_repo_url != "" || (var.gitops_workloads_repo_url != null && var.gitops_workloads_repo_url != "") ? "true" : ""
    cilium_version          = local.cilium_version
    argocd_version          = local.argocd_version
    cilium_values_b64       = base64encode(local.cilium_values_yaml)
    argocd_values_b64       = base64encode(local.argocd_values_yaml)
    extra_vars_json         = local.extra_vars_json
    requirements_yml        = local.ansible_requirements_yml
    requirements_txt        = local.ansible_requirements_txt
    playbook_path           = local.playbook_path
    bundle_playbook_relpath = "playbook.yml"
    bundle_zip_b64          = local.is_operator_connect ? "" : filebase64(data.archive_file.ansible_bundle[0].output_path)
  }

  on_node_bundle = local.is_operator_connect ? null : templatefile("${path.module}/templates/bootstrap-runner.sh.tpl", local.runner_vars)
}

# on_node bundle: a self-contained zip of the playbook + role, base64'd into the
# runner script. Built only in on_node mode — operator_connect runs the role
# straight off disk on the operator. output_path lives under .terraform (git-
# ignored runtime dir), keyed by node_name so parallel node builds don't collide.
data "archive_file" "ansible_bundle" {
  count       = local.is_operator_connect ? 0 : 1
  type        = "zip"
  source_dir  = "${path.module}/ansible"
  output_path = "${path.module}/.terraform/ansible-bundle-${var.node_name}.zip"
}

# operator_connect: triggers the Ansible install/join for exactly one node,
# ansible-playbook running here and connecting via ansible_connection_vars. Not
# created in on_node mode — there the caller (an Azure module) delivers the
# on_node_bundle output via az vm run-command and owns the execution resource.
resource "null_resource" "ansible_bootstrap" {
  count = local.is_operator_connect ? 1 : 0

  triggers = {
    node_name       = var.node_name
    node_role       = var.node_role
    playbook_path   = local.playbook_path
    extra_vars_json = local.extra_vars_json
    connection_vars = jsonencode(var.ansible_connection_vars)
  }

  provisioner "local-exec" {
    # local-exec defaults to /bin/sh (dash), which lacks `set -o pipefail`;
    # force bash. The runner's own console output is suppressed by Terraform
    # because this resource's config touches sensitive values (secret_env) —
    # tail the logfile the runner tees to for live progress.
    interpreter = ["/bin/bash", "-c"]
    environment = local.secret_env
    command     = templatefile("${path.module}/templates/bootstrap-runner.sh.tpl", local.runner_vars)
  }
}
