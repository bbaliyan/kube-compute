# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  # Deterministic default-VPC subnets for the fallback path.
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-mock-a", "subnet-mock-b"] }
  }
}

run "explicit_subnet_and_arm64" {
  command = plan
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.32.5+k3s1"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-explicit123"
  }
  assert {
    condition     = output.node_arch == "arm64"
    error_message = "m7g.* (Graviton) must derive arm64"
  }
  assert {
    condition     = output.subnet_id == "subnet-explicit123"
    error_message = "an explicit subnet_id must be used as-is"
  }
}

run "default_vpc_fallback" {
  command = plan
  variables {
    cluster_name          = "bharat"
    k8s_version           = "v1.32.5+k3s1"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    # subnet_id omitted -> null -> default-VPC fallback
  }
  assert {
    condition     = output.subnet_id == "subnet-mock-a"
    error_message = "null subnet_id must fall back to the first (sorted) default-VPC subnet"
  }
}

run "x86_64_derivation" {
  command = plan
  variables {
    cluster_name          = "x86"
    k8s_version           = "v1.32.5+k3s1"
    aws_region            = "eu-west-1"
    instance_type         = "m7i.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-x"
  }
  assert {
    condition     = output.node_arch == "x86_64"
    error_message = "m7i.* (Intel) must derive x86_64"
  }
}

run "explicit_ami_overrides_lookup" {
  command = plan
  variables {
    cluster_name          = "amitest"
    k8s_version           = "v1.32.5+k3s1"
    aws_region            = "eu-west-1"
    instance_type         = "m7g.large"
    allowed_ingress_cidrs = ["10.0.0.0/8"]
    subnet_id             = "subnet-x"
    os_image_ami_id       = "ami-0explicit123"
  }
  assert {
    condition     = output.effective_ami_id == "ami-0explicit123"
    error_message = "explicit os_image_ami_id must override the AMI lookup"
  }
}
