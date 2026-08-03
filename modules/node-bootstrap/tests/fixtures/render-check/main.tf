# SPDX-License-Identifier: Apache-2.0
terraform {
  required_version = ">= 1.12.0"
}

module "server_init" {
  source = "../../.."

  node_provider = "aws"
  cluster_name  = "test-cluster"
  node_name     = "test-cluster-cp-1"
  k8s_version   = "v1.36.1+rke2r1"
  node_role     = "server-init"

  cluster_token        = "dummy-token"
  cluster_agent_token  = "dummy-agent-token"
  control_plane_taint  = true
  cni                  = "cilium"
  extra_tls_sans       = ["1.2.3.4"]
  registration_address = null

  ansible_connection_vars = {
    ansible_connection          = "amazon.aws.aws_ssm"
    ansible_aws_ssm_instance_id = "i-0123456789abcdef0"
    ansible_aws_ssm_region      = "us-east-1"
  }
}

module "worker" {
  source = "../../.."

  node_provider = "proxmox"
  cluster_name  = "test-cluster"
  node_name     = "test-cluster-worker-1"
  k8s_version   = "v1.36.1+rke2r1"
  node_role     = "worker"

  registration_address      = "10.0.1.1"
  agent_token_fetch_command = "echo 'dummy-fetched-token'"

  ansible_connection_vars = {
    ansible_connection           = "ssh"
    ansible_host                 = "10.0.1.5"
    ansible_user                 = "almalinux"
    ansible_ssh_private_key_file = "/tmp/dummy-key"
  }
}
