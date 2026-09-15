# SPDX-License-Identifier: Apache-2.0
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 200
      ipv4_addresses = [["192.168.1.20", "127.0.0.1"]]
    }
  }
}

run "worker_pool_wiring" {
  command = plan
  variables {
    cluster_name         = "bharat"
    proxmox_node         = "pve"
    vm_cores             = 2
    vm_memory_mb         = 4096
    vm_disk_gb           = 30
    desired_count        = 2
    registration_address = "192.168.1.5"
    cluster_agent_token  = "agent-secret-abc123"
    os_image_url         = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name   = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  }

  assert {
    condition     = length(proxmox_virtual_environment_vm.worker) == 2
    error_message = "desired_count = 2 must create exactly 2 worker VMs"
  }
  assert {
    condition     = alltrue([for k, r in proxmox_virtual_environment_firewall_rules.worker : strcontains(coalesce(r.rule[0].source, ""), "kube-compute-bharat-cluster")])
    error_message = "every worker VM's firewall rule must reference the control plane's cluster ipset by name, never create its own"
  }
  assert {
    condition     = output.node_provider == "proxmox"
    error_message = "module must expose a node_provider output — kube-shell/kube-status/kube-start read it from terragrunt output to dispatch; without it they get literal JSON null and fail with \"unknown node_provider 'null'\" when run from a node-pool directory"
  }
  assert {
    condition = alltrue([
      for k, snippet in proxmox_virtual_environment_file.node_init :
      anytrue([
        for f in yamldecode(snippet.source_raw[0].data).write_files :
        strcontains(base64decode(f.content), "AGENT_TOKEN_FETCH_COMMAND='echo '\\''agent-secret-abc123'\\'''")
        if f.path == "/opt/kube-compute/secrets.env"
      ])
    ])
    error_message = "every worker's payload must carry this pool's agent-token fetch command — on Proxmox there is no secret store, so the token is embedded verbatim in an echo"
  }
  assert {
    condition = alltrue([
      for k, snippet in proxmox_virtual_environment_file.node_init :
      alltrue([
        for f in yamldecode(snippet.source_raw[0].data).write_files :
        !strcontains(base64decode(f.content), "aws ssm") && !strcontains(base64decode(f.content), "amazon.aws")
      ])
    ])
    error_message = "no part of a Proxmox worker's payload may reference an AWS SSM transport — there is no secret store here, so the token is embedded verbatim in an echo"
  }
  assert {
    condition = length(distinct([
      for k, snippet in proxmox_virtual_environment_file.node_init :
      yamldecode(snippet.source_raw[0].data).hostname
    ])) == 2
    error_message = "each worker must get a distinct hostname — rke2/kubelet register the Kubernetes node under the OS hostname"
  }
}

run "worker_fqdn_set_when_cluster_domain_present" {
  command = plan
  variables {
    cluster_name         = "bharat"
    proxmox_node         = "pve"
    vm_cores             = 2
    vm_memory_mb         = 4096
    vm_disk_gb           = 30
    desired_count        = 2
    registration_address = "192.168.1.5"
    cluster_agent_token  = "agent-secret-abc123"
    os_image_url         = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name   = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
    cluster_domain       = "example.com"
  }

  # Regression test: without an explicit fqdn key, cloud-init's cc_set_hostname
  # (this distro prefers fqdn over the literal hostname key when both are
  # ambiguous) falls back to deriving one from the VM's own current, still
  # template-baked hostname -- silently colliding every worker in the pool
  # onto that one shared hostname instead of its own distinct node_name.
  # RKE2 registers nodes by hostname, so only one worker could ever join; the
  # rest looped forever rejected with "Node password rejected, duplicate
  # hostname" (confirmed on a real 3-worker Proxmox apply).
  assert {
    condition = alltrue([
      for k, snippet in proxmox_virtual_environment_file.node_init :
      yamldecode(snippet.source_raw[0].data).fqdn == "worker-${k}.bharat.example.com"
    ])
    error_message = "each worker must get an explicit fqdn (worker-<k>.cluster_name.cluster_domain) whenever cluster_domain is set, not just hostname -- the fqdn label is deliberately shorter than node_name/hostname (no cluster_name prefix), since cluster_fqdn_suffix already carries that identity"
  }
}

run "named_pool_labels_taints_and_ingress" {
  command = plan
  variables {
    cluster_name               = "bharat"
    pool_name                  = "gpu"
    proxmox_node               = "pve"
    vm_cores                   = 2
    vm_memory_mb               = 4096
    vm_disk_gb                 = 30
    desired_count              = 2
    registration_address       = "192.168.1.5"
    cluster_agent_token        = "agent-secret-abc123"
    os_image_url               = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
    os_image_file_name         = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
    node_taints                = ["dedicated=gpu:NoSchedule"]
    allowed_ingress_cidrs      = ["192.168.1.0/24", "10.8.0.0/24"]
    ingress_ports              = [80, 443]
    cluster_domain             = "example.com"
    dns_server_address         = "192.168.1.53"
    tsig_key_name              = "kube-compute"
    tsig_key_secret            = "ZmFrZXNlY3JldA=="
    manage_wildcard_dns_record = false
  }

  assert {
    condition     = alltrue([for k, vm in proxmox_virtual_environment_vm.worker : vm.name == "bharat-gpu-${k}"])
    error_message = "workers must be named <cluster_name>-<pool_name>-<n>, or two pools of one cluster collide"
  }
  assert {
    condition = alltrue([
      for k, snippet in proxmox_virtual_environment_file.node_init :
      yamldecode(snippet.source_raw[0].data).fqdn == "gpu-${k}.bharat.example.com"
    ])
    error_message = "the fqdn label must carry the pool name, or two pools of one cluster share fqdns"
  }
  assert {
    condition = alltrue([
      for k, snippet in proxmox_virtual_environment_file.node_init :
      anytrue([
        for f in yamldecode(snippet.source_raw[0].data).write_files :
        strcontains(base64decode(f.content), "kube-compute.io/node-group=gpu") &&
        strcontains(base64decode(f.content), "dedicated=gpu:NoSchedule")
        if try(f.encoding, "") == "b64"
      ])
    ])
    error_message = "every worker must carry kube-compute.io/node-group=<pool_name> and the pool's taints"
  }
  assert {
    condition     = alltrue([for k, r in proxmox_virtual_environment_firewall_rules.worker : length(r.rule) == 5])
    error_message = "the pool must open every ingress port to every allowed CIDR, on top of the cluster rule"
  }
  assert {
    condition     = output.wildcard_dns_registration_enabled == false && module.dns_registration.record_created == false
    error_message = "manage_wildcard_dns_record = false must publish no wildcard record, even with DNS configured"
  }
}
