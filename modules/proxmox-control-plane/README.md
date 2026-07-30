# proxmox-control-plane

Provisions the control-plane node(s) for a single-cluster RKE2 deployment on Proxmox.

## Operational note: SSH connection bursts on apply

The `proxmox_virtual_environment_file` resources here (`vendor_data`, `hostname_init`,
`network_data`) upload cloud-init snippets via SSH — this is how the `bpg/proxmox`
provider handles snippet uploads, not something this module controls. Each upload opens
its own SSH connection to the Proxmox node, and OpenTofu's default per-unit resource
parallelism (10) means a single `apply` of this module can already burst close to that
many connections at once.

If a consumer applies this module concurrently with another unit that also does SSH
uploads — most commonly `proxmox-node-pool` against the same cluster — the combined
burst can exceed the Proxmox host's SSH daemon `MaxStartups` (OpenSSH's default is
`10:30:100`: begin randomly dropping unauthenticated connections once 10 are open at
once). The failure surfaces as a `bpg/proxmox` SSH auth error on an otherwise-valid
key/token (`ssh: unable to authenticate ... no supported methods remain`), lands on an
arbitrary resource, and is non-deterministic — some uploads in the same apply succeed,
others don't.

Two independent mitigations, not mutually exclusive:

- **Cap OpenTofu's per-unit parallelism** (e.g. `-parallelism=8` via consumer
  Terragrunt config) to reduce how many connections one unit can open at once. This
  only bounds a single unit — it doesn't prevent two units applying at the same time
  from together exceeding the host's threshold.
- **Raise the Proxmox host's `MaxStartups`** in `/etc/ssh/sshd_config` (e.g.
  `MaxStartups 60:30:200`), then `sshd -t && systemctl reload ssh`. This scales with
  however many units a consumer applies concurrently, independent of per-unit
  parallelism tuning, at the cost of a change outside version control on the Proxmox
  host itself.

Consumers that apply multiple Proxmox units concurrently (e.g. via a `run --all`-style
orchestrator) should expect to need the host-side change.
