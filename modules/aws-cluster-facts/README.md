# aws-cluster-facts

Generates this cluster's join tokens (`random_password.server_token`/`agent_token`)
and two AWS resources `aws-node-pool` needs to already exist (real AWS resource IDs,
not name-based references — a hard dependency, unlike Proxmox's tolerant ipsets):
`aws_security_group.cluster` and `aws_ssm_parameter.agent_token`. `aws-control-plane`
takes both as inputs instead of creating them itself.

Applies in seconds — no EC2 instance, no Ansible — so `aws-control-plane` and
`aws-node-pool` can both depend on this one fast-applying unit for their join tokens
instead of on each other, letting both apply in parallel instead of node-pool waiting
on control-plane's full bootstrap to finish first.

`registration_address` (the NLB/Route53/static join address) is explicitly NOT handled by this module yet — that's a deliberate scope boundary for a future follow-up, since AWS's three-mode addressing is more complex than Proxmox's or Azure's simpler shapes.
