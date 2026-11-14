# SPDX-License-Identifier: Apache-2.0
# The AWS ruleset is baked into the kube-devenv image (TFLINT_PLUGIN_DIR).
# Do not add `source` or `version`: tflint would then look in ~/.tflint.d.

config {
  call_module_type = "none"
}

plugin "aws" {
  enabled = true
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_naming_convention" {
  enabled = true
}
