# SPDX-License-Identifier: Apache-2.0
locals {
  cloud_init = templatefile(var.cloud_init_template, {
    cluster_name                   = var.cluster_name
    k8s_version                    = var.k8s_version
    cluster_fqdn                   = var.cluster_fqdn
    node_role                      = var.node_role
    control_plane_taint            = var.control_plane_taint
    registration_address           = var.registration_address
    agent_token_fetch_command      = var.agent_token_fetch_command
    node_labels                    = var.node_labels
    trusted_ca_pem                 = var.trusted_ca_pem
    registry_mirror_url            = var.registry_mirror_url
    gitops_platform_repo_url       = var.gitops_platform_repo_url
    gitops_platform_revision       = var.gitops_platform_revision
    gitops_workloads_repo_url      = var.gitops_workloads_repo_url
    gitops_workloads_revision      = var.gitops_workloads_revision
    gitops_workloads_path          = var.gitops_workloads_path
    cert_mode                      = var.cert_mode
    platform_extra_helm_parameters = var.platform_extra_helm_parameters
    platform_helm_values_object    = var.platform_helm_values_object
    extra_tags                     = var.extra_tags
  })
}
