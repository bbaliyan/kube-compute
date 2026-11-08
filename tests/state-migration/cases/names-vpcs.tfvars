# Two candidates in different VPCs, with no vpc_name. The first has room.
cluster_name    = "example-vpcs"
cluster_type    = "all_in_one"
instance_type   = "t3a.xlarge"
os_image_ami_id = "@os_image_ami_id@"

subnet_names = ["example-other-subnet", "example-subnet-a"]

control_plane_node_name_template = "example-k8{number}"
