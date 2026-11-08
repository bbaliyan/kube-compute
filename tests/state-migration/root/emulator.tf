# SPDX-License-Identifier: Apache-2.0
# Copied next to the module under test, the way Terragrunt adds files to a
# module it uses as the root. The endpoint and the credentials come from the
# environment (AWS_ENDPOINT_URL, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY), so
# any AWS emulator works.

terraform {
  backend "local" {}
}

provider "aws" {
  region = var.aws_region

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
}
