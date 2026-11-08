# Two candidates in one VPC. The first has no free address, so a new cluster goes to the second.
cluster_name    = "example-full"
cluster_type    = "all_in_one"
instance_type   = "t3a.xlarge"
os_image_ami_id = "@os_image_ami_id@"

vpc_name     = "example-vpc"
subnet_names = ["example-subnet-full", "example-subnet-c"]

control_plane_node_name_template = "example-k8{number}"
