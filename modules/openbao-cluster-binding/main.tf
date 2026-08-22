# SPDX-License-Identifier: Apache-2.0

# The "vault" provider (address, VAULT_TOKEN) is configured by the CALLER and
# passed in via providers = {}, not here: Terraform forbids
# count/for_each/depends_on on a module call whose module owns its own
# provider config block ("legacy module"), and callers need depends_on to
# sequence this after Stage A (SA + ClusterRoleBinding + token Secret) has
# actually been created. See README.
locals {
  auth_mount_path    = coalesce(var.auth_mount_path, "kubernetes-${var.cluster_name}")
  secret_path_prefix = coalesce(var.secret_path_prefix, "kube/${var.cluster_name}")

  # Vault/OpenBao policies live in a single GLOBAL namespace, not scoped per
  # auth mount. A fixed policy name (e.g. "eso-reader") would let a second
  # cluster's apply silently overwrite the first cluster's policy content
  # since both would collide on the same global policy object.
  policy_name = "${var.cluster_name}-eso-reader"
}

resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = local.auth_mount_path
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend                = vault_auth_backend.kubernetes.path
  kubernetes_host        = var.kubernetes_host
  kubernetes_ca_cert     = var.kubernetes_ca_cert
  token_reviewer_jwt     = var.token_reviewer_jwt
  disable_iss_validation = var.disable_iss_validation
}

resource "vault_policy" "eso_reader" {
  name = local.policy_name

  policy = join("\n", [
    for prefix in concat([local.secret_path_prefix], var.extra_secret_path_prefixes) : <<-EOT
      path "${var.vault_kv_mount}/data/${prefix}/*" {
        capabilities = ["read"]
      }
    EOT
  ])
}

resource "vault_kubernetes_auth_backend_role" "eso" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = var.role_name
  bound_service_account_names      = [var.eso_service_account_name]
  bound_service_account_namespaces = [var.eso_service_account_namespace]
  token_policies                   = [vault_policy.eso_reader.name]
  token_ttl                        = var.token_ttl_seconds
}
