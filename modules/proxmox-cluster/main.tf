# SPDX-License-Identifier: Apache-2.0

locals {
  # Same formula as proxmox-control-plane's/proxmox-node-pool's own local —
  # needed here too since this module now owns the dns provider both used to
  # self-configure.
  tsig_key_name_fqdn = "${trimsuffix(coalesce(var.tsig_key_name, "unused"), ".")}."

  # kube-platform's bootstrap chart gates the cluster-autoscaler Argo CD
  # Application on this Helm value. This module owns
  # cluster_autoscaler_enabled, so it injects it via node-bootstrap's generic
  # platform_extra_helm_parameters map rather than a dedicated parameter.
  platform_extra_helm_parameters = merge(
    var.platform_extra_helm_parameters,
    { clusterAutoscalerEnabled = tostring(var.cluster_autoscaler_enabled) },
  )

  # ---- cluster-autoscaler-workers.yaml (Cluster + Secret + ProxmoxMachineTemplate + MachineDeployment) ----
  # See templates/cluster-autoscaler-workers.yaml.tftpl for field-source
  # commentary. vm_memory_mb -> memoryMiB: despite the "_mb" name, this
  # variable is already MiB project-wide (see its own description, "RAM per
  # ... VM in MiB" — same convention as proxmox-control-plane's and
  # proxmox-node-pool's own vm_memory_mb, and the same value bpg/proxmox's
  # `memory { dedicated = ... }` block consumes directly). A prior revision
  # of this local ran it through a decimal-MB(10^6)-to-MiB(2^20) conversion
  # formula anyway, silently corrupting e.g. 8192 -> 7813 — caught on a real
  # apply: CAPMOX's CRD validation rejects non-multiple-of-8 memoryMiB
  # values outright ("spec.template.spec.memoryMiB: Invalid value: 7813
  # ... should be a multiple of 8"). No conversion is needed; pass the value
  # straight through, matching every other vm_memory_mb consumer in this
  # project.
  cluster_autoscaler_bundle_yaml = !var.cluster_autoscaler_enabled ? "" : templatefile(
    "${path.module}/templates/cluster-autoscaler-workers.yaml.tftpl",
    {
      cluster_name           = var.cluster_name
      min_size               = var.cluster_autoscaler_worker_min_size
      max_size               = var.cluster_autoscaler_worker_max_size
      vm_cores               = var.cluster_autoscaler_worker_template.vm_cores
      vm_memory_mib          = var.cluster_autoscaler_worker_template.vm_memory_mb
      vm_disk_gb             = var.cluster_autoscaler_worker_template.vm_disk_gb
      proxmox_node           = var.cluster_autoscaler_worker_template.proxmox_node
      proxmox_template_vm_id = var.cluster_autoscaler_worker_template.proxmox_template_vm_id
      disk_datastore_id      = var.cluster_autoscaler_worker_template.disk_datastore_id
      network_bridge         = var.cluster_autoscaler_worker_template.network_bridge
      dns_servers            = var.dns_servers
      ip_pool_addresses      = var.cluster_autoscaler_enabled ? var.cluster_autoscaler_worker_ip_pool.addresses : []
      ip_pool_gateway        = var.cluster_autoscaler_enabled ? var.cluster_autoscaler_worker_ip_pool.gateway : ""
      ip_pool_prefix         = var.cluster_autoscaler_enabled ? var.cluster_autoscaler_worker_ip_pool.prefix : 0
      ip_pool_metric         = var.cluster_autoscaler_enabled ? var.cluster_autoscaler_worker_ip_pool.metric : 0
      # ProxmoxCluster.spec.controlPlaneEndpoint.host rejects an empty/unset
      # value outright ("provided endpoint address is not a valid IP or
      # FQDN") — confirmed on a real apply. This ProxmoxCluster is a
      # Get()-satisfying placeholder only (see the big comment in the
      # template on why Cluster.spec.controlPlaneRef is deliberately
      # omitted), so its value is never actually consulted for anything
      # actionable here — reusing cluster_autoscaler_registration_address
      # (the same genesis self-registered DNS name autoscaler workers
      # already join through) keeps it real/resolvable without introducing
      # the module.control_plane.cluster_ip/cluster_fqdn dependency cycle
      # that local's own comment documents. 6443 is RKE2/Kubernetes' standard
      # API server port — this project never overrides it.
      # coalesce, not the bare local: cluster_domain/dns_server_address unset
      # (with cluster_autoscaler_enabled = true) is already a hard error via
      # the terraform_data.cluster_autoscaler_registration_address_configured
      # precondition below, but that precondition and this templatefile()
      # call both evaluate in the same plan — a bare null here would crash
      # templatefile() itself ("Cannot include a null value in a string
      # template") before OpenTofu gets to report the precondition's own,
      # more actionable error message. The empty-string fallback is never a
      # real value an actual apply reaches (the precondition blocks it).
      control_plane_endpoint_host = local.cluster_autoscaler_registration_address != null ? local.cluster_autoscaler_registration_address : ""
      control_plane_endpoint_port = 6443
      bootstrap_secret_b64        = var.cluster_autoscaler_enabled ? base64encode(module.cluster_autoscaler_worker_bootstrap[0].cloud_init_user_data) : ""
      # Never the manager-wide capmox-manager-credentials fallback — see
      # variables.tf's own description and the template's UNVERIFIED-item-4
      # comment for why. Empty string is unreachable at apply time: the
      # variable's own validation blocks null here whenever
      # cluster_autoscaler_enabled is true.
      capmox_credentials_secret_name = coalesce(var.cluster_autoscaler_capmox_credentials_secret_name, "")
    }
  )

  genesis_apply_manifests = !var.cluster_autoscaler_enabled ? [] : [{
    path    = "/opt/kube-compute/manifests/20-cluster-autoscaler-workers.yaml"
    content = local.cluster_autoscaler_bundle_yaml
  }]

  # Deliberately NOT module.control_plane.cluster_fqdn/cluster_ip: this
  # bundle's Secret is written into the CONTROL PLANE's own cloud-init
  # (genesis_apply_manifests, below), so referencing either output would
  # create a dependency cycle (cluster_ip resolves from the control-plane VM
  # resource, which needs this bundle's cloud-init rendered first). Instead
  # this mirrors proxmox-node-pool's own default: the genesis node's
  # single-target self-registered DNS name, computed from this module's own
  # cluster_domain/dns_server_address, no control_plane output involved.
  # Requires both variables set — validated below. cluster_fqdn (the
  # round-robin api.* record) is avoided even where it wouldn't cycle: it
  # causes 10-20+ minute join hangs (see proxmox-node-pool's
  # registration_address doc).
  cluster_autoscaler_registration_address = var.cluster_domain != null && var.dns_server_address != null ? (
    "genesis.${var.cluster_name}.${trimsuffix(var.cluster_domain, ".")}"
  ) : null
}

# Shared worker cloud-init payload for every CAPI-provisioned autoscaler
# Machine: rendered once, referenced by every MachineDeployment replica via
# the same Secret (Machine.spec.bootstrap.dataSecretName) — not one
# node-bootstrap instantiation per replica, since CAPMOX/cluster-autoscaler
# (not this module) creates the actual VMs. set_hostname = false: the payload
# is shared byte-for-byte across replicas, so it cannot carry a node-unique
# hostname — see node-bootstrap's set_hostname variable for the still-
# unverified assumption this relies on (CAPMOX's per-VM cloud-init metadata
# supplying a usable hostname instead). node_name is still required by the
# interface even though set_hostname = false means it's never written to
# cloud-config — purely a Terraform-internal label, need not be unique.
# agent_token_fetch_command mirrors proxmox-node-pool's own module call:
# every worker replica in a pool gets byte-identical values, which is why a
# single shared render works here too. cluster_agent_token is safe to read
# from module.control_plane (unlike cluster_fqdn/cluster_ip) — it comes from
# a random_password resource with no dependency on the control plane's own
# cloud-init render.
module "cluster_autoscaler_worker_bootstrap" {
  source = "../node-bootstrap"
  count  = var.cluster_autoscaler_enabled ? 1 : 0

  cluster_name              = var.cluster_name
  node_name                 = "${var.cluster_name}-autoscaler-worker"
  node_role                 = "worker"
  set_hostname              = false
  registration_address      = local.cluster_autoscaler_registration_address
  agent_token_fetch_command = "echo '${module.control_plane.cluster_agent_token}'"
  trusted_ca_pem            = var.trusted_ca_pem
  registry_mirror_url       = var.registry_mirror_url
  dns_servers               = var.dns_servers
}

# Module calls don't support lifecycle preconditions (only resources/data
# sources do), and a plain `check` block only warns rather than blocks at
# apply time (a misconfigured cluster_autoscaler_enabled = true would apply
# cleanly with a broken join address baked into every worker's Secret).
# terraform_data is a provider-less resource that DOES support lifecycle
# preconditions, used here purely to get a hard-stop precondition, matching
# proxmox-node-pool's own registration_address precondition in strictness.
resource "terraform_data" "cluster_autoscaler_registration_address_configured" {
  count = var.cluster_autoscaler_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.cluster_autoscaler_registration_address != null
      error_message = "cluster_autoscaler_enabled = true requires both cluster_domain and dns_server_address to be set — autoscaled workers join through the genesis node's self-registered DNS name, computed from those two, same as proxmox-node-pool's own default registration_address."
    }
  }
}

# The CAPI-core/CAPMOX manifests bootstrap.sh applies as capi-install.yaml
# provision their webhook TLS via cert-manager Issuer/Certificate resources —
# a hard dependency, not cosmetic. cert-manager itself is only installed by
# the platform Argo CD Application (kube-platform's wave-0
# cert-manager-app.yaml), so cluster_autoscaler_enabled = true with
# gitops_platform_enabled = false leaves capi-install.yaml with no way to
# ever succeed (confirmed on a real apply: "no matches for kind Issuer/
# Certificate in version cert-manager.io/v1: ensure CRDs are installed
# first"). Fail this at plan/apply time rather than at 03:00 in a bootstrap
# log on a booting VM.
resource "terraform_data" "cluster_autoscaler_requires_platform_gitops" {
  count = var.cluster_autoscaler_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.gitops_platform_enabled
      error_message = "cluster_autoscaler_enabled = true requires gitops_platform_enabled = true — the CAPI/CAPMOX manifests it applies depend on cert-manager, which is only installed by the platform Argo CD Application."
    }
  }
}

module "control_plane" {
  source    = "../proxmox-control-plane"
  providers = { dns = dns }

  ssh_private_key_file              = var.ssh_private_key_file
  ssh_user                          = var.ssh_user
  cluster_name                      = var.cluster_name
  trusted_ca_pem                    = var.trusted_ca_pem
  registry_mirror_url               = var.registry_mirror_url
  gitops_platform_enabled           = var.gitops_platform_enabled
  gitops_platform_repo_url_override = var.gitops_platform_repo_url_override
  gitops_platform_revision_override = var.gitops_platform_revision_override
  gitops_workloads_repo_url         = var.gitops_workloads_repo_url
  gitops_workloads_revision         = var.gitops_workloads_revision
  gitops_workloads_path             = var.gitops_workloads_path
  workloads_extra_helm_parameters   = var.workloads_extra_helm_parameters
  cluster_type                      = var.cluster_type
  cni                               = var.cni
  cert_mode                         = var.cert_mode
  platform_extra_helm_parameters    = local.platform_extra_helm_parameters
  platform_helm_values_object       = var.platform_helm_values_object
  extra_tags                        = var.extra_tags
  proxmox_node                      = var.proxmox_node
  disk_datastore_id                 = var.disk_datastore_id
  iso_datastore_id                  = var.iso_datastore_id
  network_bridge                    = var.network_bridge
  vm_cores                          = var.vm_cores
  vm_memory_mb                      = var.vm_memory_mb
  vm_disk_gb                        = var.vm_disk_gb
  vm_cpu_type                       = var.vm_cpu_type
  node_arch                         = var.node_arch
  os_image_url                      = var.os_image_url
  os_image_file_name                = var.os_image_file_name
  os_image_file_id                  = var.os_image_file_id
  proxmox_template_vm_id            = var.proxmox_template_vm_id
  ssh_authorized_keys               = var.ssh_authorized_keys
  dns_servers                       = var.dns_servers
  control_plane_count               = var.control_plane_count
  control_plane_ip_addresses        = var.control_plane_ip_addresses
  vm_gateway                        = var.vm_gateway
  cluster_network_cidr              = var.cluster_network_cidr
  allowed_ingress_cidrs             = var.allowed_ingress_cidrs
  ingress_ports                     = var.ingress_ports
  cluster_domain                    = var.cluster_domain
  dns_server_address                = var.dns_server_address
  dns_server_port                   = var.dns_server_port
  dns_transport                     = var.dns_transport
  dns_record_ttl                    = var.dns_record_ttl
  tsig_key_name                     = var.tsig_key_name
  tsig_key_algorithm                = var.tsig_key_algorithm
  tsig_key_secret                   = var.tsig_key_secret

  genesis_apply_manifests             = local.genesis_apply_manifests
  cluster_autoscaler_crd_wait_enabled = var.cluster_autoscaler_enabled
}

module "node_pools" {
  source    = "../proxmox-node-pool"
  for_each  = var.node_pools
  providers = { dns = dns }

  cluster_name        = var.cluster_name
  cluster_agent_token = module.control_plane.cluster_agent_token

  trusted_ca_pem         = each.value.trusted_ca_pem
  registry_mirror_url    = each.value.registry_mirror_url
  proxmox_node           = each.value.proxmox_node
  disk_datastore_id      = each.value.disk_datastore_id
  iso_datastore_id       = each.value.iso_datastore_id
  network_bridge         = each.value.network_bridge
  vm_cores               = each.value.vm_cores
  vm_memory_mb           = each.value.vm_memory_mb
  vm_disk_gb             = each.value.vm_disk_gb
  vm_cpu_type            = each.value.vm_cpu_type
  os_image_url           = each.value.os_image_url
  os_image_file_name     = each.value.os_image_file_name
  os_image_file_id       = each.value.os_image_file_id
  proxmox_template_vm_id = each.value.proxmox_template_vm_id
  ssh_authorized_keys    = each.value.ssh_authorized_keys
  dns_servers            = each.value.dns_servers
  worker_ip_addresses    = each.value.worker_ip_addresses
  vm_gateway             = each.value.vm_gateway
  desired_count          = each.value.desired_count
  registration_address   = each.value.registration_address
  extra_node_labels      = each.value.extra_node_labels
  cluster_domain         = each.value.cluster_domain
  dns_server_address     = each.value.dns_server_address
  dns_server_port        = each.value.dns_server_port
  dns_transport          = each.value.dns_transport
  dns_record_ttl         = each.value.dns_record_ttl
  tsig_key_name          = each.value.tsig_key_name
  tsig_key_algorithm     = each.value.tsig_key_algorithm
  tsig_key_secret        = each.value.tsig_key_secret
}

module "os_patch" {
  source = "../node-os-patch"

  control_plane_node_refs = module.control_plane.control_plane_node_refs
  worker_node_refs        = merge([for p in module.node_pools : p.worker_node_refs]...)
  ssh_user                = module.control_plane.ssh_user
  ssh_private_key_file    = module.control_plane.ssh_private_key_file
}
