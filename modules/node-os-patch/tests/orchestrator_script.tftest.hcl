# SPDX-License-Identifier: Apache-2.0
# Locks in the plain-SSH rewrite: the rendered script must cover every node
# by name, patch control-plane before workers, never mention Ansible, and
# correctly render the degenerate all_in_one case (no worker pool at all).

variables {
  ssh_user             = "almalinux"
  ssh_private_key_file = "~/.ssh/id_ed25519_kube_cluster"
  control_plane_node_refs = {
    "cluster-test-cp-0" = { instance_id = "100", ip = "10.0.0.10", provider = "proxmox" }
  }
  worker_node_refs = {
    "cluster-test-worker-0" = { instance_id = "101", ip = "10.0.0.11", provider = "proxmox" }
  }
}

run "renders_both_node_groups_with_correct_service_names" {
  command = plan

  assert {
    condition     = strcontains(output.orchestrator_script, "patch_node \"cluster-test-cp-0\" \"10.0.0.10\" \"rke2-server\"")
    error_message = "control-plane node must be patched with the rke2-server service name"
  }
  assert {
    condition     = strcontains(output.orchestrator_script, "patch_node \"cluster-test-worker-0\" \"10.0.0.11\" \"rke2-agent\"")
    error_message = "worker node must be patched with the rke2-agent service name"
  }
  assert {
    condition     = strcontains(split("=== Worker nodes", output.orchestrator_script)[0], "cluster-test-cp-0")
    error_message = "control-plane node must be patched before the worker section starts"
  }
  assert {
    condition     = !strcontains(split("=== Worker nodes", output.orchestrator_script)[0], "cluster-test-worker-0")
    error_message = "worker node must not be patched before the control-plane section finishes"
  }
  assert {
    condition     = !strcontains(output.orchestrator_script, "ansible-playbook") && !strcontains(output.orchestrator_script, "ansible.builtin")
    error_message = "the rewritten orchestrator must not invoke Ansible in any form"
  }
  assert {
    condition     = strcontains(output.orchestrator_script, "ssh_user=\"almalinux\"")
    error_message = "the SSH user must be baked into the rendered script"
  }
}

run "all_in_one_cluster_renders_an_empty_worker_section" {
  command = plan
  variables {
    worker_node_refs = {}
  }

  assert {
    condition     = !strcontains(output.orchestrator_script, "patch_node \"cluster-test-worker-0\"")
    error_message = "with no worker pool, the worker section must render no patch_node calls"
  }
  assert {
    condition     = strcontains(output.orchestrator_script, "patch_node \"cluster-test-cp-0\" \"10.0.0.10\" \"rke2-server\"")
    error_message = "the control-plane node must still be patched"
  }
}
