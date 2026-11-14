# SPDX-License-Identifier: Apache-2.0
run "no_steps_by_default" {
  command = plan

  assert {
    condition     = length(output.steps) == 0
    error_message = "an AWS node runs no boot step, and reads no instance metadata, unless asked"
  }
}

run "pod_identity_sets_the_provider_id_and_the_topology_labels" {
  command = plan

  variables {
    pod_identity_enabled = true
  }

  assert {
    condition     = [for step in output.steps : step.name] == ["aws-provider-id"]
    error_message = "pod identity must add the provider ID step although aws_provider_id is false"
  }
  assert {
    condition     = strcontains(output.steps[0].commands[0][2], "provider-id=aws:///%s/%s") && strcontains(output.steps[0].commands[0][2], "topology.kubernetes.io/zone=%s") && strcontains(output.steps[0].commands[0][2], "topology.kubernetes.io/region=%s") && strcontains(output.steps[0].commands[0][2], "node.kubernetes.io/instance-type=%s")
    error_message = "the drop-in must set the providerID and the zone, region and instance-type labels"
  }
  assert {
    condition     = strcontains(output.steps[0].commands[0][2], "placement/region")
    error_message = "the region must come from EC2 metadata"
  }
}

run "pod_identity_with_the_provider_id_adds_one_step" {
  command = plan

  variables {
    aws_provider_id      = true
    pod_identity_enabled = true
  }

  assert {
    condition     = length(output.steps) == 1
    error_message = "both switches must still give exactly one step"
  }
}

run "the_provider_id_step_alone_sets_no_topology_labels" {
  command = plan

  variables {
    aws_provider_id = true
  }

  assert {
    condition     = !strcontains(output.steps[0].commands[0][2], "topology.kubernetes.io")
    error_message = "without pod identity the step must stay as it was"
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
