# SPDX-License-Identifier: Apache-2.0
run "no_steps_by_default" {
  command = plan

  assert {
    condition     = length(output.steps) == 0
    error_message = "an AWS node runs no boot step, and reads no instance metadata, unless asked"
  }
}

run "the_provider_id_step_reads_instance_metadata" {
  command = plan

  variables {
    aws_provider_id = true
  }

  assert {
    condition     = [for step in output.steps : step.name] == ["aws-provider-id"]
    error_message = "aws_provider_id must add exactly one step"
  }
  assert {
    condition     = strcontains(output.steps[0].commands[0][2], "provider-id=aws:///%s/%s") && strcontains(output.steps[0].commands[0][2], "node-label+:\\n  - \"node.kubernetes.io/instance-type=%s\"")
    error_message = "the drop-in must set the providerID and label the node with its instance type"
  }
}
