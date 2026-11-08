# SPDX-License-Identifier: Apache-2.0
run "keys_are_written_as_yaml_strings" {
  command = plan

  variables {
    ssh_authorized_keys = ["  ssh-ed25519 AAAAC3Nza user@host # note: \"quoted\"  "]
  }

  assert {
    condition     = yamldecode(output.data).ssh_authorized_keys == ["ssh-ed25519 AAAAC3Nza user@host # note: \"quoted\""]
    error_message = "an SSH key must survive the YAML round trip unchanged, apart from the trimmed spaces"
  }
  assert {
    condition     = startswith(output.data, "#cloud-config\n")
    error_message = "cloud-init reads vendor data as cloud-config only after the #cloud-config line"
  }
  assert {
    condition     = yamldecode(output.data).write_files[0].content == "[Journal]\nStorage=persistent\n"
    error_message = "the journal must be persistent"
  }
  assert {
    condition = yamldecode(output.data).runcmd == [
      "systemctl restart systemd-journald",
      "journalctl --flush",
      "systemctl enable --now qemu-guest-agent",
      "systemctl enable --now serial-getty@ttyS0.service",
    ]
    error_message = "runcmd must restart and flush the journal, then enable the guest agent and the serial console"
  }
}

run "no_keys_writes_no_key_list" {
  command = plan

  assert {
    condition     = !can(yamldecode(output.data).ssh_authorized_keys)
    error_message = "null ssh_authorized_keys must leave the key out of the document"
  }
}
