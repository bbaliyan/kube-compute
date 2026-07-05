# SPDX-License-Identifier: Apache-2.0
variables {
  cloud_init_template = "templates/cloud-init-al2023.yaml.tpl"
}

run "with_ca_and_mirror" {
  command = plan
  variables {
    cluster_name        = "test1"
    k8s_version         = "v1.36.1+k3s1"
    trusted_ca_pem      = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    registry_mirror_url = "https://harbor.example.test"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "update-ca-trust extract")
    error_message = "CA trust must be installed when trusted_ca_pem is set"
  }
  assert {
    condition     = strcontains(nonsensitive(output.cloud_init), "https://harbor.example.test")
    error_message = "registry mirror endpoint must appear when registry_mirror_url is set"
  }
}

run "without_ca_or_mirror" {
  command = plan
  variables {
    cluster_name = "test1"
    k8s_version  = "v1.36.1+k3s1"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "update-ca-trust extract")
    error_message = "CA trust must be absent when trusted_ca_pem is null"
  }
  assert {
    condition     = !strcontains(nonsensitive(output.cloud_init), "registries.yaml")
    error_message = "registry mirror config must be absent when registry_mirror_url is null"
  }
}
