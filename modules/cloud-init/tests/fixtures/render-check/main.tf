# SPDX-License-Identifier: Apache-2.0
# Renders cloud-init with all features enabled so the cloud_init can be
# extracted and validated offline. Not for production use.
module "bootstrap" {
  source = "../../.."

  cloud_init_template       = "${path.module}/../../../templates/cloud-init-al2023.yaml.tpl"
  cluster_name              = "render-check"
  k8s_version               = "v1.36.1+k3s1"
  cluster_fqdn              = "api.render-check.example.test"
  trusted_ca_pem            = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  registry_mirror_url       = "https://harbor.example.test"
  gitops_platform_repo_url  = "https://github.com/example/kube-platform.git"
  gitops_platform_revision  = "v1.0.0"
  gitops_workloads_repo_url = "https://github.com/example/my-apps.git"
  gitops_workloads_revision = "main"
  gitops_workloads_path     = "apps"
  extra_tags                = { CostCenter = "example" }
}

output "cloud_init" {
  value     = module.bootstrap.cloud_init
  sensitive = true
}
