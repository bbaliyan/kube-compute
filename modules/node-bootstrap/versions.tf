# SPDX-License-Identifier: Apache-2.0
terraform {
  required_version = ">= 1.12.0"
  required_providers {
    # Runs `helm template` at PLAN time to render the Cilium and Argo CD
    # genesis manifests. A data source, not a provisioner: the render is
    # side-effect-free (it needs the chart and values, never cluster access),
    # its result is plan-known, and it can be mocked in `tofu test`. Nothing in
    # this module ever executes anything against the target node.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
