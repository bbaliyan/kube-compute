# Three control-plane nodes in three zones that join through a fixed address.
# ha-nlb covers the load balancer; it is slower.
cluster_name                = "example-ha"
cluster_type                = "dedicated_control_plane"
instance_type               = "t3a.large"
os_image_ami_id             = "@os_image_ami_id@"
control_plane_count         = 3
endpoint_mode               = "static"
static_registration_address = "10.0.1.10"

control_plane_subnets = {
  "eu-west-1a" = "@subnet_a@"
  "eu-west-1b" = "@subnet_b@"
  "eu-west-1c" = "@subnet_c@"
}

vpc_name     = "example-vpc"
subnet_names = ["example-subnet-a"]
