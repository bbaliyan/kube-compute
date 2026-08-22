# openbao-cluster-binding

Registers a single Kubernetes API server's identity with OpenBao's
(Vault-API-compatible) `kubernetes` auth method, so that External Secrets
Operator (ESO) running in that cluster can authenticate to OpenBao and read
secrets. Given a host/CA/reviewer-JWT triple, this module creates a dedicated
auth mount, a read-only policy scoped to that cluster's own secret path
prefix, and an auth backend role binding ESO's ServiceAccount to that policy.

## What this module does

Four `vault_*` resources, using the `hashicorp/vault` provider (which speaks
OpenBao's Vault-API-compatible protocol natively):

1. `vault_auth_backend` — a dedicated `kubernetes`-type auth mount for this
   cluster.
2. `vault_kubernetes_auth_backend_config` — tells that mount which API server
   and CA to trust, and which reviewer JWT to use for TokenReview calls.
3. `vault_policy` — grants `read` on this cluster's own KV path prefix, and
   nothing else.
4. `vault_kubernetes_auth_backend_role` — binds ESO's ServiceAccount
   (name + namespace) to that policy, on that mount.

## Why this shape

- **One dedicated auth mount per cluster, not a shared mount.** Vault/OpenBao's
  `kubernetes` auth method can only trust ONE `kubernetes_host`/CA pair per
  auth mount path. A homelab/fleet running multiple clusters — and, in
  future, vClusters (lightweight virtual control planes running as workloads
  inside a parent cluster, each with their own distinct API server/CA/SA
  namespace) — needs one mount per cluster identity, not a single mount
  juggling multiple hosts. This module therefore always creates its own
  mount, named `kubernetes-<cluster_name>` by convention unless the caller
  overrides `auth_mount_path`.
- **Generic about what "a Kubernetes API server" is.** This module takes a
  host/CA/reviewer-JWT triple as plain inputs and doesn't care whether they
  came from a real standalone cluster or from a vCluster's own generated
  kubeconfig. That's the intended reuse path for vClusters later: same
  module, just feed it the vCluster's own host/CA instead of the parent
  cluster's.
- **Stage B of a two-phase bootstrap.** Stage A (cluster genesis, outside
  this module's scope — handled by this project's kube-platform GitOps
  bootstrap) must already have created:
  - the ServiceAccount ESO runs as,
  - a ClusterRoleBinding granting it `system:auth-delegator` (so OpenBao's
    TokenReview callback is itself authorized to call the Kubernetes API),
  - a long-lived `kubernetes.io/service-account-token`-type Secret for that
    SA.

  The caller reads that Secret's token out-of-band and passes it in as
  `token_reviewer_jwt`. This module does not create Kubernetes objects — it
  only owns the OpenBao/Vault-provider side, matching this repo's existing
  convention of zero `kubernetes` provider usage anywhere in kube-compute.
  GitOps/Helm owns all in-cluster objects; Terraform owns infra plus this
  OpenBao registration.
- **Policy name is prefixed with `cluster_name`, not fixed.** Vault/OpenBao
  policies are named in a single GLOBAL namespace, not scoped per auth mount.
  If this module used a fixed policy name (e.g. `"eso-reader"`) for every
  cluster, a second cluster's apply would silently overwrite the first
  cluster's policy content since they'd collide on the same global policy
  object. Prefixing with `cluster_name` (`<cluster_name>-eso-reader`) avoids
  that.

## Inputs of note

- `token_reviewer_jwt` must come from the long-lived Secret-backed SA token
  created in Stage A — never from an ad-hoc `kubectl create token`. A
  `kubectl create token` JWT expires (default one hour) and gets a new value
  every time it's minted, which would make every subsequent `terraform plan`
  see drift and try to rewrite the auth config. The Secret-backed token is
  stable across applies.
- `auth_mount_path` and `secret_path_prefix` both default to
  `cluster_name`-derived values (`kubernetes-<cluster_name>` and
  `kube/<cluster_name>` respectively) and only need overriding if a caller
  wants a different naming convention.
- `disable_iss_validation` defaults to `true` and should stay that way for
  RKE2 clusters: RKE2's ServiceAccount token issuer defaults to a
  cluster-internal-only URL (`https://kubernetes.default.svc.cluster.local`)
  that OpenBao, running outside the cluster, cannot reach to fetch an OIDC
  discovery document. TokenReview (not issuer/OIDC validation) is the only
  validation path available here.

## Provider configuration: the caller's job, not this module's

This module has no `provider "vault" {}` block. The `vault` provider needs
`address` set, and typically reads `VAULT_TOKEN` from the environment rather
than a Terraform input — this module never accepts the OpenBao admin/root
token as a variable; that's the caller's provider-level credential, never
something this module should see as a plain input. Terraform also forbids
`count`/`for_each`/`depends_on` on a module call targeting a module that owns
its own provider config block (a "legacy module"). Callers invoking this
module virtually always need `depends_on` — to sequence the OpenBao
registration after Stage A has actually created the SA/ClusterRoleBinding/
Secret — so the `provider "vault" {}` block lives in the **caller** instead,
which then passes its configured provider down explicitly:

```hcl
provider "vault" {
  address = var.openbao_address
  # VAULT_TOKEN read from the environment, not a Terraform variable.
}

module "openbao_cluster_binding" {
  source     = "../openbao-cluster-binding"
  providers  = { vault = vault }
  depends_on = [module.cluster_genesis]

  cluster_name        = var.cluster_name
  kubernetes_host      = var.kubernetes_host
  kubernetes_ca_cert   = var.kubernetes_ca_cert
  token_reviewer_jwt   = var.eso_token_reviewer_jwt
}
```

## What this module does *not* do

- Configure the `vault` provider — the caller's job, per above.
- Create the ServiceAccount, ClusterRoleBinding, or token Secret that Stage A
  is responsible for — those are Kubernetes objects, out of scope for a
  module that owns zero `kubernetes` provider usage.
- Create or manage the KV v2 mount itself (`vault_kv_mount`) — this module
  assumes it already exists and only writes a policy scoped to a path prefix
  within it.
- Decide *when* to run relative to cluster genesis — the caller's job via
  `depends_on`.
