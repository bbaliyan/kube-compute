# SPDX-License-Identifier: Apache-2.0
# Renders cloud-init with all features enabled so the cloud_init can be
# extracted and validated offline. Not for production use.
module "bootstrap" {
  source = "../../.."

  cloud_init_template  = "${path.module}/../../../templates/cloud-init-almalinux-10.yaml.tpl"
  cluster_name         = "render-check"
  k8s_version          = "v1.36.1+rke2r1"
  cluster_fqdn         = "api.render-check.example.test"
  cluster_fqdn_suffix  = "render-check.example.test"
  trusted_ca_pem       = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
  registry_mirror_url  = "https://harbor.example.test"
  gitops_root_repo_url = "https://github.com/example/kube-root-app.git"
  gitops_root_revision = "v1.0.0"
  gitops_root_path     = "render-check"
  extra_tags           = { CostCenter = "example" }
}

output "cloud_init" {
  value     = module.bootstrap.cloud_init
  sensitive = true
}
