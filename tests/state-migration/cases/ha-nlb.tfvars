# Three control-plane nodes in three zones behind an internal load balancer.
# The provider waits about 65 seconds for the load balancer, so this case is not in the default set.
# "dns" is not used: it adds CloudWatch alarms, which not every emulator decodes.
cluster_name        = "example-ha-nlb"
cluster_type        = "dedicated_control_plane"
instance_type       = "t3a.large"
control_plane_count = 3
endpoint_mode       = "loadbalancer"

control_plane_subnets = {
  "eu-west-1a" = "@subnet_a@"
  "eu-west-1b" = "@subnet_b@"
  "eu-west-1c" = "@subnet_c@"
}
