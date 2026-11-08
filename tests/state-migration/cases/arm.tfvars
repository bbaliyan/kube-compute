# Graviton control plane, one arm64 and one x86_64 static group, and one arm64 and one
# x86_64 autoscaled pool. A node's architecture comes from its instance type.
# Each group takes the seed AMI of its own architecture, as the lookup by name would.
cluster_name    = "example-arm"
cluster_type    = "dedicated_control_plane"
instance_type   = "m7g.large"
os_image_ami_id = "@os_image_ami_id_arm64@"

static_nodes = {
  platform = {
    node_count          = 1
    instance_type       = "m7g.xlarge"
    root_volume_size_gb = 40
    node_name_template  = "example-kp{number}"
    os_image_ami_id     = "@os_image_ami_id_arm64@"
  }
  legacy = {
    node_count          = 1
    instance_type       = "t3a.large"
    root_volume_size_gb = 40
    node_name_template  = "example-kx{number}"
    os_image_ami_id     = "@os_image_ami_id@"
  }
}
platform_node_group = "platform"

autoscaled_nodes = {
  workers-arm = {
    instance_types      = ["c7g.xlarge"]
    max_cpu_cores       = 4
    max_memory_gib      = 8
    os_image_ami_id     = "@os_image_ami_id_arm64@"
    root_volume_size_gb = 40
  }
  workers-x86 = {
    instance_types      = ["c6a.xlarge"]
    max_cpu_cores       = 4
    max_memory_gib      = 8
    os_image_ami_id     = "@os_image_ami_id@"
    root_volume_size_gb = 40
  }
}

# The VPC and the subnet exist. The case passes the subnet by ID.
subnet_id = "@subnet_a@"
