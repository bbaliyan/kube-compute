# SPDX-License-Identifier: Apache-2.0

variable "control_plane_node_refs" {
  description = "Control-plane node refs, unmodified from a *-control-plane module's own control_plane_node_refs output (map of node name -> {instance_id, ip, provider}). Patched one at a time — etcd tolerates losing at most one control-plane node at once."
  type = map(object({
    instance_id = string
    ip          = string
    provider    = string
  }))
}

variable "worker_node_refs" {
  description = "Worker node refs, unmodified from one or more *-node-pool modules' own worker_node_refs outputs, merged by the caller if more than one pool. Defaults to {} for an all_in_one cluster shape with no separate worker pool."
  type = map(object({
    instance_id = string
    ip          = string
    provider    = string
  }))
  default = {}
}

variable "ssh_user" {
  description = "SSH user the orchestrator connects as, passed through from the same *-control-plane module's ssh_user output — day-2 guest access only; node-bootstrap itself never connects to the node."
  type        = string
}

variable "ssh_private_key_file" {
  description = "Path to the SSH private key, passed straight through from the same *-control-plane module's ssh_private_key_file output. Not marked sensitive: a path, not the key material itself."
  type        = string
}

variable "rke2_server_service" {
  description = "systemd unit name the orchestrator script waits on after rebooting a control-plane node."
  type        = string
  default     = "rke2-server"
}

variable "rke2_agent_service" {
  description = "systemd unit name the orchestrator script waits on after rebooting a worker node."
  type        = string
  default     = "rke2-agent"
}
