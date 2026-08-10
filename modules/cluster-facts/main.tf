# SPDX-License-Identifier: Apache-2.0
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
