# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-al2023.yaml.tpl"
}

run "core_render" {
  command = plan

  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
  }

  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "#cloud-config")
    error_message = "rendered output must be a cloud-config document"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "stage-4:k8s-install")
    error_message = "core install stage must be present"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "stage-7:kubeconfig-publish")
    error_message = "kubeconfig-publish stage must be present"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "INSTALL_K3S_VERSION=\"v1.36.1+k3s1\"")
    error_message = "k8s_version must be injected into the K3s install"
  }
}
