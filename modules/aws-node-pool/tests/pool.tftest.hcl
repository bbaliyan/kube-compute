# SPDX-License-Identifier: Apache-2.0
mock_provider "aws" {
  mock_data "aws_ec2_instance_type" {
    defaults = { supported_architectures = ["arm64"] }
  }
  # aws_autoscaling_group's launch_template.id argument is schema-validated as
  # "lt-<alphanumeric>"-shaped — the mock provider's default random string for a
  # computed launch-template id fails that validation. A static, valid-looking id
  # sidesteps it (same fix pattern aws-control-plane/tests uses for aws_lb's arn).
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
}

run "fixed_pool_is_an_asg_on_the_cluster_sg" {
  command = plan
  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  variables {
    cluster_name              = "bharat"
    aws_region                = "eu-west-1"
    registration_address      = "10.0.1.5"
    agent_token_ssm_parameter = "/kube-compute/bharat/agent-token"
    cluster_security_group_id = "sg-cluster123"
    subnet_id                 = "subnet-worker-a"
    instance_type              = "m7g.large"
    desired_count             = 3
  }
  # Fixed-size ASG: min = max = desired_capacity = desired_count, no scaling policies.
  assert {
    condition     = aws_autoscaling_group.worker.min_size == 3 && aws_autoscaling_group.worker.max_size == 3 && aws_autoscaling_group.worker.desired_capacity == 3
    error_message = "a fixed pool must set min_size = max_size = desired_capacity = desired_count"
  }
  assert {
    condition     = aws_autoscaling_group.worker.launch_template[0].id == aws_launch_template.worker.id
    error_message = "the ASG must use this module's own launch template"
  }
  assert {
    condition     = contains(aws_autoscaling_group.worker.vpc_zone_identifier, "subnet-worker-a")
    error_message = "the ASG must be pinned to the pool's own subnet"
  }
  assert {
    condition     = contains(aws_launch_template.worker.vpc_security_group_ids, "sg-cluster123")
    error_message = "every worker must attach the control plane's cluster security group"
  }
  assert {
    condition     = aws_launch_template.worker.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be enforced"
  }
  assert {
    condition     = length(aws_launch_template.worker.user_data) > 0
    error_message = "launch template must carry the combined (SSM-agent + node-bootstrap) user-data"
  }
  assert {
    condition     = output.availability_zone == "eu-west-1a"
    error_message = "availability_zone output must reflect the subnet's AZ"
  }
  assert {
    condition     = output.autoscaling_group_name == aws_autoscaling_group.worker.name
    error_message = "autoscaling_group_name output must expose the ASG for verb-script instance discovery"
  }
}

run "os_image_name_lookup" {
  command = plan
  override_data {
    target = data.aws_subnet.selected
    values = { availability_zone = "eu-west-1a", vpc_id = "vpc-mock" }
  }
  override_data {
    target = data.aws_ami.by_name
    values = { id = "ami-byname789" }
  }
  variables {
    cluster_name              = "byname"
    aws_region                = "eu-west-1"
    registration_address      = "10.0.1.5"
    agent_token_ssm_parameter = "/kube-compute/byname/agent-token"
    cluster_security_group_id = "sg-cluster123"
    subnet_id                 = "subnet-worker-a"
    instance_type             = "m7g.large"
    os_image_name             = "almalinux10-arm64-kube-image-*"
  }
  assert {
    condition     = aws_launch_template.worker.image_id == "ami-byname789"
    error_message = "os_image_name should resolve to the looked-up AMI ID"
  }
}
