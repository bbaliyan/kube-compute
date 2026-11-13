# SPDX-License-Identifier: Apache-2.0
# Pins the exact boot steps of every control-plane node on Proxmox. A step that belongs to
# another provider (SSM Agent, the AWS provider ID) cannot appear here, and the Proxmox
# steps (the iSCSI initiator name everywhere, DNS self-registration on genesis only) are
# here. Plan only: nothing is created.
mock_provider "proxmox" {
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/demo.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}

override_resource {
  target = random_password.server_token
  values = { result = "server-token-for-the-steps-test" }
}

override_resource {
  target = random_password.agent_token
  values = { result = "agent-token-for-the-steps-test" }
}

variables {
  cluster_name           = "steps"
  proxmox_node           = "pve"
  vm_cores               = 4
  vm_memory_mb           = 8192
  vm_disk_gb             = 50
  control_plane_count    = 3
  cluster_domain         = "example.test"
  cluster_network_cidr   = "192.168.1.0/24"
  allowed_ingress_cidrs  = ["192.168.1.0/24"]
  proxmox_template_vm_id = 9000
  dns_server_address     = "192.168.1.53"
  tsig_key_name          = "kube-compute"
  tsig_key_secret        = "ZmFrZXNlY3JldA=="
}

run "genesis_and_joining_server_steps" {
  command = plan

  assert {
    condition = module.node_bootstrap["0"].boot_steps == [
      "iscsi-initiator",
      "dns-self-register",
      "kubelet-reserved",
      "graceful-shutdown",
      "prelude",
      "skew-check",
      "rejoin-probe",
      "node-config-server",
      "platform-clone",
      "api-skew-check",
      "genesis-cilium-manifest",
      "start-server-init",
      "start-server-join",
      "wait-ready-server",
      "genesis-cilium-handoff",
      "genesis-argocd",
      "finish",
      "os-auto-updates",
    ]
    error_message = "the Proxmox genesis node must run exactly these steps"
  }

  assert {
    condition = module.node_bootstrap["1"].boot_steps == [
      "iscsi-initiator",
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
    error_message = "the Proxmox joining server must run exactly these steps, with no DNS self-registration"
  }

  assert {
    condition     = module.node_bootstrap["2"].boot_steps == module.node_bootstrap["1"].boot_steps
    error_message = "every joining server runs the same steps"
  }
}

run "without_a_dns_server_genesis_does_not_self_register" {
  command = plan

  variables {
    control_plane_count = 1
    dns_server_address  = null
    tsig_key_name       = null
    tsig_key_secret     = null
  }

  assert {
    condition     = !contains(module.node_bootstrap["0"].boot_steps, "dns-self-register") && contains(module.node_bootstrap["0"].boot_steps, "iscsi-initiator")
    error_message = "without dns_server_address genesis must keep the iSCSI step and drop DNS self-registration"
  }
}

run "no_aws_step_reaches_a_proxmox_node" {
  command = plan

  assert {
    condition = !anytrue([
      for name in concat(module.node_bootstrap["0"].boot_steps, module.node_bootstrap["1"].boot_steps) :
      contains(["ssm-agent", "aws-provider-id"], name)
    ])
    error_message = "SSM Agent and the AWS provider ID are AWS steps"
  }
  assert {
    condition     = !strcontains(nonsensitive(module.node_bootstrap["0"].cloud_init_user_data), "169.254.169.254") && !strcontains(nonsensitive(module.node_bootstrap["0"].cloud_init_user_data), "amazon-ssm-agent")
    error_message = "the user data of a Proxmox node must name neither instance metadata nor SSM Agent"
  }
}
