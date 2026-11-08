# Three control-plane nodes behind an internal load balancer, in three zones.
cluster_name        = "example-ha"
cluster_type        = "dedicated_control_plane"
instance_type       = "t3a.large"
control_plane_count = 3
endpoint_mode       = "loadbalancer"

control_plane_subnets = {
  "eu-west-1a" = "@subnet_a@"
  "eu-west-1b" = "@subnet_b@"
  "eu-west-1c" = "@subnet_c@"
}
