# cluster-facts

Provider-neutral core: join tokens and `k8s_version`, the values every unit in a
multi-node cluster needs early — before any Ansible run — with zero dependency on any
other Terraform resource. No cloud provider is configured or referenced here (only
`hashicorp/random`); provider-specific early-needed resources (a security group, a Key
Vault, etc.) live in that provider's own `{provider}-cluster-facts` wrapper module,
which calls this module and re-exports its outputs alongside its own.

Applies in seconds. `control-plane` and `node-pool` (via their provider's wrapper) both
depend on this module for their join tokens and `k8s_version`, but never on each other —
letting both apply in parallel instead of node-pool waiting on control-plane's full
bootstrap to finish first.
