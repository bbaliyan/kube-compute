# SPDX-License-Identifier: Apache-2.0
terraform {
  required_version = ">= 1.12.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    # on_node mode only: zips the playbook + role into the run-command bundle.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}
