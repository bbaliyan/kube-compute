# SPDX-License-Identifier: Apache-2.0
# Guards the cluster_autoscaler_* variable validation (fails fast, not a raw
# "Attempt to get attribute from null value" deep in node-bootstrap), and the
# CAPI-core-only bundle this module now renders and threads through to
# proxmox-control-plane's genesis_apply_manifests: no CAPRKE2/RKE2ConfigTemplate
# anywhere in the rendered output — a direct regression check that the drop
# from the plan's revision actually took, not merely that new content was
# added alongside the old.
mock_provider "proxmox" {
  mock_resource "proxmox_download_file" {
    defaults = { id = "local:iso/bharat.img" }
  }
  mock_resource "proxmox_virtual_environment_file" {
    defaults = { id = "local:snippets/bharat.yaml" }
  }
  mock_resource "proxmox_virtual_environment_vm" {
    defaults = {
      vm_id          = 100
      ipv4_addresses = [["192.168.1.10", "127.0.0.1"]]
    }
  }
}
mock_provider "dns" {}

variables {
  cluster_name          = "bharat"
  proxmox_node          = "pve"
  vm_cores              = 4
  vm_memory_mb          = 8192
  vm_disk_gb            = 50
  allowed_ingress_cidrs = ["192.168.1.0/24"]
  os_image_url          = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
  os_image_file_name    = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
}

run "cluster_autoscaler_enabled_without_template_fails_validation" {
  command = plan
  variables {
    cluster_domain                     = "example.test"
    dns_server_address                 = "10.0.0.53"
    tsig_key_name                      = "test-key"
    tsig_key_secret                    = "dGVzdC1zZWNyZXQ="
    control_plane_count                = 1
    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 1
    cluster_autoscaler_worker_max_size = 3
  }
  expect_failures = [var.cluster_autoscaler_worker_template, var.cluster_autoscaler_worker_ip_pool]
}

run "cluster_autoscaler_enabled_with_zero_max_size_fails_validation" {
  command = plan
  variables {
    cluster_domain      = "example.test"
    dns_server_address  = "10.0.0.53"
    tsig_key_name       = "test-key"
    tsig_key_secret     = "dGVzdC1zZWNyZXQ="
    control_plane_count = 1

    cluster_autoscaler_enabled = true
    cluster_autoscaler_worker_template = {
      vm_cores               = 4
      vm_memory_mb            = 4096
      vm_disk_gb              = 40
      proxmox_template_vm_id  = 9100
      network_bridge          = "vmbr0"
      disk_datastore_id       = "local-lvm"
      proxmox_node            = "pve1"
    }
    cluster_autoscaler_worker_ip_pool = {
      addresses = ["192.168.1.230-192.168.1.240"]
      gateway   = "192.168.1.1"
      prefix    = 24
    }
  }
  expect_failures = [var.cluster_autoscaler_worker_max_size]
}

run "cluster_autoscaler_disabled_by_default_produces_no_bundle" {
  command = plan

  assert {
    condition     = length(local.genesis_apply_manifests) == 0
    error_message = "cluster_autoscaler_enabled defaults to false — genesis_apply_manifests must be empty"
  }
  assert {
    condition     = length(module.cluster_autoscaler_worker_bootstrap) == 0
    error_message = "cluster_autoscaler_enabled defaults to false — no cluster_autoscaler_worker_bootstrap instance should exist"
  }
}

run "cluster_autoscaler_enabled_renders_capi_core_bundle_no_caprke2" {
  # apply (not plan): the shared worker bootstrap's agent_token_fetch_command
  # embeds module.control_plane's random_password-backed cluster_agent_token
  # output, unknown at plan time — same precedent as composition.tftest.hcl's
  # "one_pool_creates_its_workers_and_shares_the_agent_token" run.
  command = apply

  variables {
    cluster_domain      = "example.test"
    dns_server_address  = "10.0.0.53"
    tsig_key_name       = "test-key"
    tsig_key_secret     = "dGVzdC1zZWNyZXQ="
    control_plane_count = 1

    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 1
    cluster_autoscaler_worker_max_size = 3
    cluster_autoscaler_worker_template = {
      vm_cores               = 4
      vm_memory_mb            = 4096
      vm_disk_gb              = 40
      proxmox_template_vm_id  = 9100
      network_bridge          = "vmbr0"
      disk_datastore_id       = "local-lvm"
      proxmox_node            = "pve1"
    }
    cluster_autoscaler_worker_ip_pool = {
      addresses = ["192.168.1.230-192.168.1.240"]
      gateway   = "192.168.1.1"
      prefix    = 24
    }
  }

  assert {
    condition     = length(local.genesis_apply_manifests) == 1
    error_message = "cluster_autoscaler_enabled = true must produce exactly one genesis_apply_manifests entry"
  }
  assert {
    condition     = length(module.cluster_autoscaler_worker_bootstrap) == 1
    error_message = "cluster_autoscaler_enabled = true must render exactly one shared worker cloud-init payload"
  }
  assert {
    condition = anytrue([
      for m in local.genesis_apply_manifests :
      strcontains(m.content, "kind: Cluster") &&
      strcontains(m.content, "kind: Secret") &&
      strcontains(m.content, "kind: ProxmoxMachineTemplate") &&
      strcontains(m.content, "kind: MachineDeployment")
    ])
    error_message = "the bundle must carry Cluster + Secret + ProxmoxMachineTemplate + MachineDeployment"
  }
  assert {
    condition = alltrue([
      for m in local.genesis_apply_manifests : !strcontains(m.content, "kind: RKE2ConfigTemplate")
    ])
    error_message = "regression check: no object of kind RKE2ConfigTemplate must ever appear in the rendered bundle — CAPRKE2 is dropped entirely in favor of Machine.spec.bootstrap.dataSecretName"
  }
  assert {
    condition = anytrue([
      for m in local.genesis_apply_manifests : strcontains(m.content, "dataSecretName: bharat-autoscaler-worker-bootstrap")
    ])
    error_message = "the MachineDeployment must reference the plain Secret via dataSecretName, not a bootstrap-provider configRef"
  }
  assert {
    condition     = local.cluster_autoscaler_bundle_yaml == local.genesis_apply_manifests[0].content
    error_message = "the genesis_apply_manifests entry content must match the rendered bundle"
  }
  assert {
    condition = anytrue([
      for m in local.genesis_apply_manifests : strcontains(m.content, "memoryMiB: 4096")
    ])
    error_message = "vm_memory_mb is already MiB (same convention as every other vm_memory_mb in this project) — it must pass through to memoryMiB unconverted, not through a decimal-MB(10^6)-to-MiB(2^20) formula (that formula previously corrupted 8192 -> 7813 on a real apply, rejected by CAPMOX's CRD validation for not being a multiple of 8)"
  }
  assert {
    condition = anytrue([
      for m in local.genesis_apply_manifests : strcontains(m.content, "dnsServers:") && strcontains(m.content, "- 1.1.1.1") && strcontains(m.content, "- 8.8.8.8")
    ])
    error_message = "ProxmoxCluster.spec.dnsServers is required by CAPMOX's CRD validation (rejected an empty spec: {} on a real apply) — must be populated from this module's own dns_servers input"
  }
  assert {
    condition = anytrue([
      for m in local.genesis_apply_manifests :
      strcontains(m.content, "ipv4Config:") &&
      strcontains(m.content, "- 192.168.1.230-192.168.1.240") &&
      strcontains(m.content, "gateway: 192.168.1.1") &&
      strcontains(m.content, "prefix: 24")
    ])
    error_message = "ProxmoxCluster.spec.ipv4Config is required by CAPMOX's CRD validation (CAPMOX has no DHCP mode — rejected an empty spec on a real apply) — must be populated from cluster_autoscaler_worker_ip_pool"
  }
  assert {
    condition = anytrue([
      for m in local.genesis_apply_manifests :
      strcontains(m.content, "controlPlaneEndpoint:") &&
      strcontains(m.content, "host: genesis.bharat.example.test") &&
      strcontains(m.content, "port: 6443")
    ])
    error_message = "ProxmoxCluster.spec.controlPlaneEndpoint.host rejects empty (CAPMOX's CRD validation on a real apply) — must be populated from cluster_autoscaler_registration_address, not left blank"
  }
}

run "cluster_autoscaler_enabled_without_dns_registration_fails_check" {
  command = plan

  variables {
    cluster_autoscaler_enabled         = true
    cluster_autoscaler_worker_min_size = 1
    cluster_autoscaler_worker_max_size = 3
    cluster_autoscaler_worker_template = {
      vm_cores               = 4
      vm_memory_mb            = 4096
      vm_disk_gb              = 40
      proxmox_template_vm_id  = 9100
      network_bridge          = "vmbr0"
      disk_datastore_id       = "local-lvm"
      proxmox_node            = "pve1"
    }
    cluster_autoscaler_worker_ip_pool = {
      addresses = ["192.168.1.230-192.168.1.240"]
      gateway   = "192.168.1.1"
      prefix    = 24
    }
  }

  # cluster_domain/dns_server_address are both unset here, so
  # cluster_autoscaler_registration_address is null and the
  # terraform_data resource's lifecycle precondition fails — a real
  # apply-blocking failure, not just a warning (see main.tf's comment on
  # why terraform_data is used here instead of a plain check block).
  expect_failures = [terraform_data.cluster_autoscaler_registration_address_configured]
}
