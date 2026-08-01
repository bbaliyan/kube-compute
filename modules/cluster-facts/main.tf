# SPDX-License-Identifier: Apache-2.0
module "component_versions" {
  source = "../component-versions"
}

locals {
  # Same repo/revision this cluster's own platform Application actually
  # tracks (platform_repo_url_override/platform_revision_override — already
  # this module's existing override surface, see variables.tf), not a
  # separately-maintained pin — so a fork or pinned revision override is
  # honored here too, not just by node-bootstrap's Argo CD wiring.
  effective_platform_repo_url = coalesce(var.platform_repo_url_override, module.component_versions.pinned_platform_repo_url)
  effective_platform_revision = coalesce(var.platform_revision_override, module.component_versions.pinned_platform_revision)

  # GitHub-specific: rewrites a github.com HTTPS clone URL into its
  # raw.githubusercontent.com content-serving equivalent. Only GitHub is
  # supported by this transform — an override pointing at a different git
  # host has no equivalent rewrite here and falls through to
  # component-versions' static default below instead (see the try() in
  # k8s_version).
  platform_versions_raw_url = "${replace(trimsuffix(local.effective_platform_repo_url, ".git"), "https://github.com/", "https://raw.githubusercontent.com/")}/${local.effective_platform_revision}/platform/platform-versions/values.yaml"
}

data "http" "platform_versions" {
  # Skip the fetch entirely when the caller already pinned an explicit
  # version — no network dependency for a plan/apply that doesn't need it.
  count = var.k8s_version == null ? 1 : 0
  url   = local.platform_versions_raw_url
}

locals {
  # Falls back through: explicit caller override -> live fetch from
  # platform/platform-versions/values.yaml on the repo/revision this cluster
  # actually tracks -> component-versions' static default (network failure,
  # non-GitHub host, or a fork that hasn't added the file yet).
  k8s_version = coalesce(
    var.k8s_version,
    try(yamldecode(one(data.http.platform_versions[*].response_body)).k8sVersion, null),
    module.component_versions.k8s_version,
  )
}

# Join-token flow: pre-generated here (not in each provider's control-plane module) so
# both control-plane and node-pool can depend on this one fast-applying unit instead of
# on each other. Two tokens, least privilege: the server token grants joining
# etcd/control-plane; the agent token is all a worker ever receives, so a compromised
# worker cannot rejoin as a control-plane/etcd member.
resource "random_password" "server_token" {
  length  = 48
  special = false
}

resource "random_password" "agent_token" {
  length  = 48
  special = false
}
