# One node that runs the control plane and the workloads.
cluster_name  = "example-single"
cluster_type  = "all_in_one"
instance_type = "t3a.xlarge"
os_image_ami_id = "@os_image_ami_id@"

# The VPC and the subnet belong to someone else. The case finds them by name.
vpc_name     = "example-vpc"
subnet_names = ["example-subnet-a"]
