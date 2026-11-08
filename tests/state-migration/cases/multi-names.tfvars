# A dedicated control plane, a static platform node and an autoscaled worker pool.
cluster_name  = "example-multi"
cluster_type  = "dedicated_control_plane"
instance_type = "t4g.large"
os_image_ami_id = "@os_image_ami_id@"

static_nodes = {
  platform = {
    node_count          = 1
    instance_type       = "r6g.large"
    root_volume_size_gb = 40
    node_name_template  = "example-kw{number}"
    os_image_ami_id     = "@os_image_ami_id@"
  }
}
platform_node_group = "platform"

autoscaled_nodes = {
  workers = {
    instance_types      = ["r6a.large"]
    max_cpu_cores       = 4
    max_memory_gib      = 32
    os_image_ami_id     = "@os_image_ami_id@"
    root_volume_size_gb = 40
  }
}

# The VPC and the subnet belong to someone else. The case finds them by name.
vpc_name     = "example-vpc"
subnet_names = ["example-subnet-a"]
