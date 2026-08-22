# SPDX-License-Identifier: Apache-2.0

output "auth_mount_path" {
  description = "Pass this as the ClusterSecretStore's auth.kubernetes.mountPath."
  value       = local.auth_mount_path
}

output "role_name" {
  description = "Name of the Kubernetes auth backend role bound to the ESO ServiceAccount."
  value       = vault_kubernetes_auth_backend_role.eso.role_name
}

output "policy_name" {
  description = "Name of the OpenBao policy granting read access to this cluster's secrets."
  value       = vault_policy.eso_reader.name
}

output "secret_path_prefix" {
  description = "KV path prefix this cluster's ExternalSecrets may read. Prefix every ExternalSecret's remoteRef.key with this value."
  value       = local.secret_path_prefix
}
