# One node that runs the control plane and the workloads.
cluster_name    = "example-single-ids"
cluster_type    = "all_in_one"
instance_type   = "t3a.xlarge"
os_image_ami_id = "@os_image_ami_id@"

# The VPC and the subnet exist. The case passes the subnet by ID.
subnet_id = "@subnet_a@"
