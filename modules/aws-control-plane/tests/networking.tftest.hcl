# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  # Deterministic default-VPC subnets for the fallback path.
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-mock-a", "subnet-mock-b"] }
  }
  # Default to arm64 (Graviton); runs that need x86_64 use override_data below.
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
}

variables {
  aws_region            = "eu-west-1"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
}

run "explicit_subnet_and_arm64" {
  command = plan
  variables {
    cluster_name  = "bharat"
    k8s_version   = "v1.36.2+rke2r1"
    instance_type = "m7g.large"
    subnet_id     = "subnet-explicit123"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "instance type reporting arm64 in AWS metadata must produce arm64 node_arch"
  }
  assert {
    condition     = output.subnet_id == "subnet-explicit123"
    error_message = "an explicit subnet_id must be used as-is"
  }
}

run "subnet_name_lookup" {
  command = plan
  override_data {
    target = data.aws_subnet.by_name
    values = { id = "subnet-byname456" }
  }
  variables {
    cluster_name = "byname"
    subnet_name  = "my-private-subnet-az1"
  }
  assert {
    condition     = output.subnet_id == "subnet-byname456"
    error_message = "subnet_name should resolve to the looked-up subnet ID"
  }
}

run "default_vpc_fallback" {
  command = plan
  variables {
    cluster_name  = "bharat"
    k8s_version   = "v1.36.2+rke2r1"
    instance_type = "m7g.large"
    # subnet_id omitted -> null -> default-VPC fallback
  }
  assert {
    condition     = output.subnet_id == "subnet-mock-a"
    error_message = "null subnet_id must fall back to the first (sorted) default-VPC subnet"
  }
}

run "x86_64_derivation" {
  command = plan
  # Tell the mock that this instance type reports x86_64.
  override_data {
    target = data.aws_ec2_instance_type.selected
    values = { supported_architectures = ["x86_64"] }
  }
  variables {
    cluster_name  = "x86"
    k8s_version   = "v1.36.2+rke2r1"
    instance_type = "m7i.large"
    subnet_id     = "subnet-x"
  }
  assert {
    condition     = output.node_arch == "x86_64"
    error_message = "instance type reporting x86_64 in AWS metadata must produce x86_64 node_arch"
  }
}

run "explicit_ami_overrides_lookup" {
  command = plan
  variables {
    cluster_name    = "amitest"
    k8s_version     = "v1.36.2+rke2r1"
    instance_type   = "m7g.large"
    subnet_id       = "subnet-x"
    os_image_ami_id = "ami-0explicit123"
  }
  assert {
    condition     = output.effective_ami_id == "ami-0explicit123"
    error_message = "explicit os_image_ami_id must override the AMI lookup"
  }
}

# Previously broken with the regex approach: im4gn is a Graviton storage family
# (family prefix "im", not matched by the old i[0-9]+g pattern).
# The data-source approach handles it correctly regardless of naming convention.
run "storage_graviton_arm64" {
  command = plan
  variables {
    cluster_name  = "storage"
    k8s_version   = "v1.36.2+rke2r1"
    instance_type = "im4gn.large"
    subnet_id     = "subnet-x"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "im4gn.large is Graviton-based; AWS API reports arm64"
  }
}
