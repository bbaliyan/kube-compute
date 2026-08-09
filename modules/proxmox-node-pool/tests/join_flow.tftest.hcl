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
        !strcontains(base64decode(f.content), "aws_ssm") && !strcontains(base64decode(f.content), "amazon.aws")
        if f.path == "/opt/kube-compute/bootstrap.sh"
      ])
    ])
    error_message = "a Proxmox worker's bootstrap payload must never reference an AWS SSM transport"
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
