# SPDX-License-Identifier: Apache-2.0
# The boot program is a list of steps that Terraform picks by role. These tests pin the
# exact list for each role, so a step cannot reach a role it does not belong to. The
# list also holds the cloud-init commands that run around the program.

variables {
  cluster_name = "test"
  node_name    = "test-node"
  node_role    = "server-init"
}

run "every_step_file_is_in_the_catalog" {
  command = plan

  assert {
    condition     = toset([for step in local.boot_step_catalog : step.file]) == local.boot_step_files_on_disk
    error_message = "every file in files/steps must be in boot_step_catalog, and every catalog entry must have its file"
  }
  assert {
    condition     = length(distinct([for step in local.boot_step_catalog : step.name])) == length(local.boot_step_catalog)
    error_message = "every step name must be unique"
  }
}

run "genesis_node_steps" {
  command = plan

  variables {
    node_role                = "server-init"
    cluster_token            = "tok"
    cluster_agent_token      = "agenttok"
    gitops_platform_repo_url = "https://example.test/platform.git"
  }

  assert {
    condition = output.boot_steps == [
      "kubelet-reserved",
      "graceful-shutdown",
      "prelude",
      "skew-check",
      "node-config-server",
      "platform-clone",
      "genesis-cilium-manifest",
      "start-server-init",
      "wait-ready-server",
      "genesis-cilium-handoff",
      "genesis-argocd",
      "finish",
      "os-auto-updates",
    ]
    error_message = "a genesis node with Cilium and the platform must run exactly these steps"
  }
}

run "genesis_node_without_cni_or_platform_has_no_genesis_step" {
  command = plan

  variables {
    node_role                 = "server-init"
    cluster_token             = "tok"
    cni                       = "default"
    gitops_platform_enabled   = false
    gitops_workloads_repo_url = null
    os_auto_updates           = false
  }

  assert {
    condition = output.boot_steps == [
      "kubelet-reserved",
      "graceful-shutdown",
      "prelude",
      "skew-check",
      "node-config-server",
      "start-server-init",
      "wait-ready-server",
      "finish",
    ]
    error_message = "with no Cilium and no Argo CD a genesis node must run no step that reads the platform ref"
  }
}

run "genesis_node_that_can_rejoin_and_has_every_option" {
  command = plan

  variables {
    node_role                = "server-init"
    cluster_token            = "tok"
    cluster_agent_token      = "agenttok"
    gitops_platform_repo_url = "https://example.test/platform.git"
    registration_address     = "api.test.example"
    trusted_ca_pem           = "-----BEGIN CERTIFICATE-----\nZHVtbXk=\n-----END CERTIFICATE-----\n"
    graceful_shutdown        = {}
    extra_server_manifests   = { "one.yaml" = "kind: ConfigMap\n" }
    genesis_apply_manifests  = [{ path = "/opt/kube-compute/manifests/20-one.yaml", content = "kind: ConfigMap\n" }]
    provider_steps           = [{ name = "provider-step", commands = [["true"]] }]
  }

  assert {
    condition = output.boot_steps == [
      "provider-step",
      "kubelet-reserved",
      "trusted-ca",
      "graceful-shutdown",
      "prelude",
      "skew-check",
      "rejoin-probe",
      "node-config-server",
      "platform-clone",
      "api-skew-check",
      "genesis-cilium-manifest",
      "genesis-extra-manifests",
      "start-server-init",
      "start-server-join",
      "wait-ready-server",
      "genesis-cilium-handoff",
      "genesis-argocd",
      "genesis-apply-manifests",
      "finish",
      "os-auto-updates",
    ]
    error_message = "a genesis node that can rejoin, with every option, must run exactly these steps"
  }
}

run "joining_server_steps" {
  command = plan

  variables {
    node_role            = "server-join"
    cluster_token        = "tok"
    registration_address = "api.test.example"
  }

  assert {
    condition = output.boot_steps == [
      "kubelet-reserved",
      "graceful-shutdown",
      "prelude",
      "skew-check",
      "node-config-server",
      "api-skew-check",
      "start-server-join",
      "wait-ready-server",
      "finish",
      "os-auto-updates",
    ]
    error_message = "a joining server must run exactly these steps and no genesis step"
  }
}

run "agent_steps" {
  command = plan

  variables {
    node_role                 = "worker"
    registration_address      = "api.test.example"
    agent_token_fetch_command = "echo tok"
  }

  assert {
    condition = output.boot_steps == [
      "kubelet-reserved",
      "graceful-shutdown",
      "prelude",
      "node-config-agent",
      "start-agent",
      "wait-ready-agent",
      "finish",
      "os-auto-updates",
    ]
    error_message = "an agent must run exactly these steps: no server step and no genesis step"
  }
  assert {
    condition     = !strcontains(local.bootstrap_program, "rke2-server") && !strcontains(local.bootstrap_program, "check_rke2_skew")
    error_message = "an agent's program must hold no server logic"
  }
}

run "a_server_program_has_no_agent_logic" {
  command = plan

  variables {
    node_role     = "server-join"
    cluster_token = "tok"
  }

  assert {
    condition     = !strcontains(local.bootstrap_program, "rke2-agent") && !strcontains(local.bootstrap_program, "AGENT_TOKEN_FETCH_COMMAND")
    error_message = "a server's program must hold no agent logic"
  }
}

run "the_ca_is_a_file_and_a_command_not_shell_logic" {
  command = plan

  variables {
    node_role                 = "worker"
    registration_address      = "api.test.example"
    agent_token_fetch_command = "echo tok"
    trusted_ca_pem            = "-----BEGIN CERTIFICATE-----\nZHVtbXk=\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      f.permissions == "0644" if f.path == "/etc/pki/ca-trust/source/anchors/trusted-ca.crt"
    ])
    error_message = "cloud-init must write the trusted CA"
  }
  assert {
    condition     = contains(yamldecode(output.cloud_init_user_data).runcmd, ["update-ca-trust", "extract"])
    error_message = "cloud-init must run update-ca-trust"
  }
  assert {
    condition     = !strcontains(local.bootstrap_program, "update-ca-trust extract") && !strcontains(local.bootstrap_program, "TRUSTED_CA")
    error_message = "the boot program must hold no CA logic"
  }
}

run "an_image_ca_is_checked_before_the_trust_store_is_rebuilt" {
  command = plan

  variables {
    node_role                 = "worker"
    registration_address      = "api.test.example"
    agent_token_fetch_command = "echo tok"
    trusted_ca_pem            = "-----BEGIN CERTIFICATE-----\nZHVtbXk=\n-----END CERTIFICATE-----\n"
    trusted_ca_in_image       = true
  }

  assert {
    condition = !contains(
      [for f in yamldecode(output.cloud_init_user_data).write_files : f.path],
      "/etc/pki/ca-trust/source/anchors/trusted-ca.crt"
    )
    error_message = "a CA that the image bakes must not travel in user data"
  }
  assert {
    condition = anytrue([
      for c in yamldecode(output.cloud_init_user_data).runcmd :
      strcontains(join(" ", c), "test -s /etc/pki/ca-trust/source/anchors/trusted-ca.crt") && strcontains(join(" ", c), "update-ca-trust extract")
    ])
    error_message = "a missing image CA must be reported before the trust store is rebuilt"
  }
}

run "the_join_config_is_declarative" {
  command = plan

  variables {
    node_role            = "server-join"
    cluster_token        = "tok"
    registration_address = "api.test.example"
  }

  assert {
    condition = anytrue([
      for f in yamldecode(output.cloud_init_user_data).write_files :
      startswith(base64decode(f.content), "server: https://api.test.example:9345\ntoken: \"tok\"\n")
      if f.path == "/etc/rancher/rke2/config.yaml"
    ])
    error_message = "a joining server's config.yaml must name the server and carry the token"
  }
  assert {
    condition     = !strcontains(local.bootstrap_program, "registries") && !strcontains(local.bootstrap_program, "preflight")
    error_message = "the boot program must hold no registry mirror logic"
  }
}
