# One node whose name holds the zone. The subnet comes from subnet_names, so the zone is known only through the candidate.
cluster_name    = "example-zone"
cluster_type    = "all_in_one"
instance_type   = "t3a.xlarge"
os_image_ami_id = "@os_image_ami_id@"

vpc_name     = "example-vpc"
subnet_names = ["example-subnet-b"]

control_plane_node_name_template = "example-{zone}-k8{number}"
