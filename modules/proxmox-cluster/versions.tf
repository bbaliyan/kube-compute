# SPDX-License-Identifier: Apache-2.0
terraform {
  required_version = ">= 1.12.0"
  required_providers {
    dns = {
      source                = "hashicorp/dns"
      version               = "~> 3.6"
      configuration_aliases = [dns]
    }
  }
}
