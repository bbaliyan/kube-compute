# azure-cluster-facts

Azure's thin wrapper around the shared `cluster-facts` core. Adds the whole Key Vault
write-side chain (vault → self role-assignment → secret) and the cluster Application
Security Group — both confirmed hard dependencies `azure-node-pool` references by real
resource ID (ticket 03 of the `parallelize-multinode-apply` wayfinder map), the same
shape as AWS's security group. `azure-node-pool`'s own read-side role assignment
(each worker's managed identity reading its token) is unchanged — it's inherently
node-pool-internal, since it needs the worker VM's own identity, which doesn't exist
until node-pool creates it.

**Unverified assumption:** that Azure RBAC role-assignment scopes need their target
resource to already exist (same shape as AWS's hard security-group dependency). No
cloud connectivity to confirm here — verify on a real Azure apply before relying on
this.

`registration_address` (the internal Standard Load Balancer's frontend IP) is explicitly
NOT handled by this module yet — that's a deliberate scope boundary for a future
follow-up, since it's a dynamically-assigned Azure resource attribute, not a
plan-known value this module could self-register the way Proxmox's genesis node can.
