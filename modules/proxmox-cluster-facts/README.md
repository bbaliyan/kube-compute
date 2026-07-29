# proxmox-cluster-facts

Proxmox's thin wrapper around the shared `cluster-facts` core. Adds the ipset-naming
convention (`cluster_ipset_name`/`etcd_ipset_name`) as a plan-known string — no
resource dependency, since Proxmox's firewall API resolves ipset references by name
regardless of whether the ipset resource exists yet (confirmed empirically: today's
`proxmox-control-plane` already creates the ipset and a same-apply firewall rule
referencing it by name with zero explicit Terraform dependency edge between them, and
this already applies successfully). The ipset *resources* themselves stay in
`proxmox-control-plane` — this module only owns the name.
