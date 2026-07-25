# SPDX-License-Identifier: Apache-2.0
locals {
  playbook_path = coalesce(var.ansible_playbook_path, "${path.module}/ansible/playbook.yml")

  # Bundled alongside this module's own playbook/roles, not the (possibly
  # overridden) playbook_path — these pin the connection-plugin dependencies
  # this module's supported transports need (amazon.aws + boto3 for AWS SSM),
  # independent of which playbook content a caller substitutes.
  ansible_requirements_yml = "${path.module}/ansible/requirements.yml"
  ansible_requirements_txt = "${path.module}/ansible/requirements.txt"

  # Non-secret extra-vars only. Secrets (cluster_token, cluster_agent_token,
  # agent_token_fetch_command) are deliberately excluded here — see Ticket 03's
  # decision — and instead flow through the local-exec `environment` block below.
  extra_vars = merge(var.ansible_connection_vars, {
    cluster_name                        = var.cluster_name
    node_name                           = var.node_name
    k8s_version                         = var.k8s_version
    cluster_fqdn                        = var.cluster_fqdn != null ? var.cluster_fqdn : ""
    node_role                           = var.node_role
    control_plane_taint                 = var.control_plane_taint
    registration_address                = var.registration_address != null ? var.registration_address : ""
    extra_tls_sans                      = var.extra_tls_sans
    cni                                 = var.cni
    cilium_version                      = var.cilium_version != null ? var.cilium_version : ""
    registry_mirror_url                 = var.registry_mirror_url != null ? var.registry_mirror_url : ""
    etcd_snapshot_enabled               = var.etcd_snapshot_enabled
    etcd_snapshot_schedule_cron         = var.etcd_snapshot_schedule_cron
    etcd_snapshot_retention             = var.etcd_snapshot_retention
    etcd_snapshot_object_store_bucket   = var.etcd_snapshot_object_store_bucket != null ? var.etcd_snapshot_object_store_bucket : ""
    etcd_snapshot_object_store_region   = var.etcd_snapshot_object_store_region != null ? var.etcd_snapshot_object_store_region : ""
    etcd_snapshot_object_store_endpoint = var.etcd_snapshot_object_store_endpoint != null ? var.etcd_snapshot_object_store_endpoint : ""
    etcd_snapshot_object_store_folder   = var.etcd_snapshot_object_store_folder != null ? var.etcd_snapshot_object_store_folder : ""
    node_labels                         = var.node_labels
    extra_server_manifests              = var.extra_server_manifests
    gitops_platform_repo_url            = var.gitops_platform_repo_url != null ? var.gitops_platform_repo_url : ""
    argocd_version                      = var.argocd_version != null ? var.argocd_version : ""
    gitops_platform_revision            = var.gitops_platform_revision
    gitops_workloads_repo_url           = var.gitops_workloads_repo_url != null ? var.gitops_workloads_repo_url : ""
    gitops_workloads_revision           = var.gitops_workloads_revision
    gitops_workloads_path               = var.gitops_workloads_path
    cert_mode                           = var.cert_mode
    platform_extra_helm_parameters      = var.platform_extra_helm_parameters
    platform_helm_values_object         = var.platform_helm_values_object != null ? var.platform_helm_values_object : {}
    extra_tags                          = var.extra_tags
  })

  extra_vars_json = jsonencode(local.extra_vars)

  # Secrets, gated on presence rather than node_role: the caller (a provider
  # module) already decides which tokens a given role receives — server-init
  # gets both tokens, server-join gets cluster_token only, worker gets only
  # agent_token_fetch_command. Mirroring that here (instead of hardcoding role
  # checks) means this module doesn't need to know provider-module policy.
  # trusted_ca_pem gets the same treatment as the join secrets, per Ticket 03's
  # principle — never a file, never an extra-var.
  secret_env = merge(
    var.cluster_token != null ? { CLUSTER_TOKEN = var.cluster_token } : {},
    var.cluster_agent_token != null ? { CLUSTER_AGENT_TOKEN = var.cluster_agent_token } : {},
    var.agent_token_fetch_command != null ? { AGENT_TOKEN_FETCH_COMMAND = var.agent_token_fetch_command } : {},
    var.trusted_ca_pem != null ? { TRUSTED_CA_PEM = var.trusted_ca_pem } : {},
  )
}

# Triggers Ansible install/join for exactly one node, given a role already
# assigned by the caller — this module never decides "how many nodes, which
# role" (that stays in the provider modules, per Ticket 04's decision).
resource "null_resource" "ansible_bootstrap" {
  triggers = {
    node_name       = var.node_name
    node_role       = var.node_role
    playbook_path   = local.playbook_path
    extra_vars_json = local.extra_vars_json
    connection_vars = jsonencode(var.ansible_connection_vars)
  }

  provisioner "local-exec" {
    # local-exec defaults to /bin/sh (dash on Debian, which this command's
    # host image — kube-devenv — is based on), and dash doesn't support
    # `set -o pipefail`. Force bash explicitly rather than drop pipefail.
    interpreter = ["/bin/bash", "-c"]
    environment = local.secret_env

    command = <<-EOT
      set -euo pipefail
      # This provisioner's own live console output is unconditionally
      # suppressed by Terraform/OpenTofu the moment ANY value in this
      # resource's config touches something sensitive (CLUSTER_TOKEN etc.
      # below) — a static, config-level decision, not based on what the
      # command actually prints. Ansible's own console output is already
      # secret-safe (every secret-touching task in the role sets
      # no_log: true), so mirror everything to a local logfile the operator
      # can `tail -f` from a second terminal for live progress during a long
      # apply — no change to how secrets flow, nothing new written that
      # wasn't already safe to print.
      BOOTSTRAP_LOG="/tmp/kube-compute-bootstrap-${var.node_name}.log"
      exec > >(tee "$BOOTSTRAP_LOG") 2>&1
      echo "kube-compute: bootstrap log for ${var.node_name} -> $BOOTSTRAP_LOG"
      # Force a locale Ansible/Python can always initialize, regardless of
      # what the calling shell forwards in (e.g. a host terminal's
      # en_US.UTF-8 that isn't installed in this container) — kube-devenv
      # defaults LANG/LC_ALL the same way, but a container/session can
      # override that default, and this command can't rely on it.
      export LANG=C.UTF-8
      export LC_ALL=C.UTF-8
      # Collections/Python deps are playbook-specific, not baked into the
      # devenv image (kube-devenv ships ansible-core only) — installed here so
      # a version bump is a kube-compute-only change. Both are no-ops (no
      # network call beyond a version check) once the pinned version is
      # already present, so this doesn't meaningfully slow down repeat applies.
      ansible-galaxy collection install -r "${local.ansible_requirements_yml}"
      pip3 install --quiet --break-system-packages -r "${local.ansible_requirements_txt}"
      EXTRA_VARS_FILE="$(mktemp)"
      trap 'rm -f "$EXTRA_VARS_FILE"' EXIT
      cat >"$EXTRA_VARS_FILE" <<'KUBE_COMPUTE_EXTRA_VARS_EOF'
      ${local.extra_vars_json}
      KUBE_COMPUTE_EXTRA_VARS_EOF
      ansible-playbook -i '${var.node_name},' -e "@$EXTRA_VARS_FILE" "${local.playbook_path}"
    EOT
  }
}
