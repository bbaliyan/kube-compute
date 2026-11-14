# SPDX-License-Identifier: Apache-2.0
# The service account issuer. Every server gets the API server flag. Only the genesis node
# publishes the signing keys, between the readiness wait and the Argo CD step.

variables {
  cluster_name             = "test"
  node_name                = "test-node"
  node_role                = "server-init"
  cluster_token            = "tok"
  cluster_agent_token      = "agenttok"
  gitops_platform_repo_url = "https://example.test/platform.git"
}

run "nothing_changes_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local.rke2_config, "service-account-issuer") && !strcontains(local.rke2_config, "kube-apiserver-arg")
    error_message = "the RKE2 config must not name an issuer unless asked"
  }
  assert {
    condition     = !contains(output.boot_steps, "genesis-publish-service-account-keys") && !strcontains(local.node_env, "SERVICE_ACCOUNT")
    error_message = "no publish step and no issuer values unless asked"
  }
}

run "the_genesis_node_sets_the_issuer_and_publishes_the_keys" {
  command = plan

  variables {
    service_account_issuer_url = "https://d111111abcdef8.cloudfront.net"
    service_account_keys_s3    = { bucket = "keys-bucket", region = "eu-west-1" }
  }

  assert {
    condition     = strcontains(local.rke2_config, "kube-apiserver-arg:\n  - \"service-account-issuer=https://d111111abcdef8.cloudfront.net\"\n")
    error_message = "the API server flag must carry the exact issuer URL"
  }
  assert {
    condition = (
      index(output.boot_steps, "wait-ready-server") < index(output.boot_steps, "genesis-publish-service-account-keys") &&
      index(output.boot_steps, "genesis-publish-service-account-keys") < index(output.boot_steps, "genesis-argocd")
    )
    error_message = "the keys must be published after the readiness wait and before Argo CD"
  }
  assert {
    condition     = strcontains(local.node_env, "SERVICE_ACCOUNT_KEYS_BUCKET='keys-bucket'") && strcontains(local.node_env, "SERVICE_ACCOUNT_KEYS_REGION='eu-west-1'") && strcontains(local.node_env, "SERVICE_ACCOUNT_ISSUER_URL='https://d111111abcdef8.cloudfront.net'")
    error_message = "the publish step reads the bucket, region and issuer from node.env"
  }
}

run "a_joining_server_sets_the_issuer_and_publishes_nothing" {
  command = plan

  variables {
    node_role                  = "server-join"
    registration_address       = "api.test.example"
    service_account_issuer_url = "https://d111111abcdef8.cloudfront.net"
  }

  assert {
    condition     = strcontains(local.rke2_config, "service-account-issuer=https://d111111abcdef8.cloudfront.net")
    error_message = "a joining server signs and validates tokens, so it needs the flag"
  }
  assert {
    condition     = !contains(output.boot_steps, "genesis-publish-service-account-keys")
    error_message = "only the genesis node publishes the keys"
  }
}

run "an_agent_has_no_issuer_flag" {
  command = plan

  variables {
    node_role                  = "worker"
    registration_address       = "api.test.example"
    agent_token_ssm            = { parameter = "/kube-compute/test/agent-token", region = "eu-west-1" }
    service_account_issuer_url = "https://d111111abcdef8.cloudfront.net"
  }

  assert {
    condition     = !strcontains(local.rke2_config, "service-account-issuer")
    error_message = "an agent runs no API server"
  }
}

run "a_trailing_slash_is_refused" {
  command = plan

  variables {
    service_account_issuer_url = "https://d111111abcdef8.cloudfront.net/"
  }

  expect_failures = [var.service_account_issuer_url]
}

run "keys_need_an_issuer" {
  command = plan

  variables {
    service_account_keys_s3 = { bucket = "keys-bucket", region = "eu-west-1" }
  }

  expect_failures = [var.service_account_keys_s3]
}
