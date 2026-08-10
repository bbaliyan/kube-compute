# SPDX-License-Identifier: Apache-2.0
# Regression test for a real bug: OpenTofu drops null-valued root outputs from
# state entirely, which breaks any Terragrunt `dependency` block referencing
# that attribute the moment its value is null — discovered when a real
# proxmox-control-plane apply hit "This object does not have an attribute
# named platform_repo_url_override" because the value was unset (null) rather
# than "". These outputs must never be null, regardless of whether the
# corresponding variable is set.
run "unset_overrides_output_empty_string_not_null" {
  command = plan

  assert {
    condition     = output.platform_repo_url_override == ""
    error_message = "platform_repo_url_override must output \"\" (never null) when unset, or Terragrunt dependency blocks referencing it break the moment the value is actually unset"
  }
  assert {
    condition     = output.platform_revision_override == ""
    error_message = "platform_revision_override must output \"\" (never null) when unset"
  }
  assert {
    condition     = output.workloads_repo_url == ""
    error_message = "workloads_repo_url must output \"\" (never null) when unset"
  }
}

run "set_overrides_pass_through_verbatim" {
  command = plan
  variables {
    platform_repo_url_override = "https://example.test/fork.git"
    platform_revision_override = "v1.2.3"
    workloads_repo_url         = "https://example.test/workloads.git"
  }

  assert {
    condition     = output.platform_repo_url_override == "https://example.test/fork.git"
    error_message = "an explicitly set override must pass through verbatim"
  }
  assert {
    condition     = output.platform_revision_override == "v1.2.3"
    error_message = "an explicitly set override must pass through verbatim"
  }
  assert {
    condition     = output.workloads_repo_url == "https://example.test/workloads.git"
    error_message = "an explicitly set workloads_repo_url must pass through verbatim"
  }
}
