# aws-cluster-facts

AWS's thin wrapper around the shared `cluster-facts` core. Adds two resources
`aws-node-pool` needs to already exist (real AWS resource IDs, not name-based
references — a hard dependency, unlike Proxmox's tolerant ipsets):
`aws_security_group.cluster` and `aws_ssm_parameter.agent_token`. `aws-control-plane`
takes both as inputs instead of creating them itself.

`registration_address` (the NLB/Route53/static join address) is explicitly NOT handled by this module yet — that's a deliberate scope boundary for a future follow-up, since AWS's three-mode addressing is more complex than Proxmox's or Azure's simpler shapes.
