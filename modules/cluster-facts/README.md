# cluster-facts

Provider-neutral core: join tokens, the values every unit in a multi-node cluster needs
early — before any Ansible run — with zero dependency on any other Terraform resource.
No cloud provider is configured or referenced here (only `hashicorp/random`);
provider-specific early-needed resources (a security group, an SSM parameter, etc.)
live in that provider's own `{provider}-cluster-facts` wrapper module, which calls this
module and re-exports its outputs alongside its own.

Applies in seconds. `control-plane` and `node-pool` (via their provider's wrapper) both
depend on this module for their join tokens, but never on each other — letting both
apply in parallel instead of node-pool waiting on control-plane's full bootstrap to
finish first.

`k8s_version` used to live here too (a live fetch from kube-platform's
`platform-versions.yaml`, falling back to `component-versions`' static pin) but was
retired: since the kube-image cutover, the RKE2 version is baked into the node image at
build time, not resolved at `apply` time — nothing in this repo consumes a Terraform-level
`k8s_version` anymore.
