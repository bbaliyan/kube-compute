# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  # Fall back to the platform-wide default
  # when a caller doesn't override these.
  k8s_version    = coalesce(var.k8s_version, module.component_versions.k8s_version)
  cilium_version = coalesce(var.cilium_version, module.component_versions.cilium_version)
  argocd_version = coalesce(var.argocd_version, module.component_versions.argocd_version)

  # Passed into the template as base64 rather than rendered as a literal
  # bash heredoc inside it: a nested heredoc (values file, inside the
  # boot script's own outer content, itself run after an
  # `exec > >(tee ...) 2>&1` redirect) failed unreproducibly on a real
  # node-bootstrap apply (kube-compute's Ansible-driven bootstrap path) with
  # "here-document ... delimited by end-of-file" — root cause never
  # conclusively pinned down despite substantial effort. Rather than risk
  # the same failure mode here too, computed once as a plain Terraform
  # string (safe: `%{ if ~}` evaluated by Terraform itself, no bash
  # involved) and decoded with a single `base64 -d` in the template — no
  # heredoc, no nesting, nothing left to reason about. See
  # .scratch/cilium-argocd-gitops-handoff/map.md in the kube-claude repo.
  cilium_values_yaml = <<-EOT
    kubeProxyReplacement: true
    k8sServiceHost: "127.0.0.1"
    k8sServicePort: 6443
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

  argocd_values_yaml = <<-EOT
    configs:
      params:
        server.insecure: "true"
  EOT

  cloud_init = templatefile(var.cloud_init_template, {
    cluster_name                        = var.cluster_name
    node_name                           = var.node_name
    k8s_version                         = local.k8s_version
    cilium_version                      = local.cilium_version
    argocd_version                      = local.argocd_version
    cilium_values_b64                   = base64encode(local.cilium_values_yaml)
    argocd_values_b64                   = base64encode(local.argocd_values_yaml)
    cluster_fqdn                        = var.cluster_fqdn
    node_role                           = var.node_role
    control_plane_taint                 = var.control_plane_taint
    cluster_token                       = var.cluster_token
    cluster_agent_token                 = var.cluster_agent_token
    registration_address                = var.registration_address
    agent_token_fetch_command           = var.agent_token_fetch_command
    node_labels                         = var.node_labels
    extra_tls_sans                      = var.extra_tls_sans
    cni                                 = var.cni
    cilium_operator_replicas            = var.cilium_operator_replicas
    etcd_snapshot_enabled               = var.etcd_snapshot_enabled
    etcd_snapshot_schedule_cron         = var.etcd_snapshot_schedule_cron
    etcd_snapshot_retention             = var.etcd_snapshot_retention
    etcd_snapshot_object_store_bucket   = var.etcd_snapshot_object_store_bucket
    etcd_snapshot_object_store_region   = var.etcd_snapshot_object_store_region
    etcd_snapshot_object_store_endpoint = var.etcd_snapshot_object_store_endpoint
    etcd_snapshot_object_store_folder   = var.etcd_snapshot_object_store_folder
    trusted_ca_pem                      = var.trusted_ca_pem
    registry_mirror_url                 = var.registry_mirror_url
    gitops_platform_repo_url            = var.gitops_platform_repo_url
    gitops_platform_revision            = var.gitops_platform_revision
    gitops_workloads_repo_url           = var.gitops_workloads_repo_url
    gitops_workloads_revision           = var.gitops_workloads_revision
    gitops_workloads_path               = var.gitops_workloads_path
    cert_mode                           = var.cert_mode
    platform_extra_helm_parameters      = var.platform_extra_helm_parameters
    platform_helm_values_object         = var.platform_helm_values_object
    extra_tags                          = var.extra_tags
    extra_server_manifests              = var.extra_server_manifests
  })
}
