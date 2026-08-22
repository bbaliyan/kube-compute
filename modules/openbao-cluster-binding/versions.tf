# SPDX-License-Identifier: Apache-2.0
terraform {
  required_version = ">= 1.12.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}
