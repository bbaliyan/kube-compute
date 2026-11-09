# SPDX-License-Identifier: Apache-2.0
variables {
  cluster_name = "demo"
  node_name    = "demo-cp-0"
}

run "the_iscsi_initiator_is_a_file_and_a_restart" {
  command = plan

  variables {
    node_fqdn_label = "cp-0"
  }

  assert {
    condition     = [for step in output.steps : step.name] == ["iscsi-initiator"]
    error_message = "with no DNS self-registration the only step is the iSCSI initiator name"
  }
  assert {
    condition     = output.steps[0].commands == [["systemctl", "restart", "iscsid"]]
    error_message = "iscsid must restart to read the new name"
  }
  assert {
    condition = (
      length(nonsensitive(output.files)) == 1 &&
      nonsensitive(output.files)[0].path == "/etc/iscsi/initiatorname.iscsi" &&
      nonsensitive(output.files)[0].content == "InitiatorName=iqn.2026.lan.demo:cp-0\n" &&
      nonsensitive(output.files)[0].permissions == "0644"
    )
    error_message = "cloud-init must write the deterministic initiator name"
  }
}

run "the_initiator_label_falls_back_to_the_node_name" {
  command = plan

  assert {
    condition     = nonsensitive(output.files)[0].content == "InitiatorName=iqn.2026.lan.demo:demo-cp-0\n"
    error_message = "without node_fqdn_label the node name names the initiator"
  }
}

run "dns_self_registration_adds_a_step_and_two_private_files" {
  command = plan

  variables {
    dns_self_register_zone        = "example.test"
    dns_self_register_record_name = "genesis.demo"
    dns_self_register_ttl         = 30
    dns_server_address            = "192.168.1.53"
    dns_transport                 = "tcp4"
    tsig_key_name                 = "kube-compute"
    tsig_key_secret               = "ZmFrZXNlY3JldA=="
  }

  assert {
    condition     = [for step in output.steps : step.name] == ["iscsi-initiator", "dns-self-register"]
    error_message = "DNS self-registration must follow the iSCSI step"
  }
  assert {
    condition     = strcontains(output.steps[1].commands[0][2], "nsupdate -v -4 -k /run/kube-compute-nsupdate.key")
    error_message = "a tcp4 transport must pass -v and -4 to nsupdate, and the key must come from a file"
  }
  assert {
    condition = (
      nonsensitive(output.files)[1].path == "/run/kube-compute-nsupdate.key" &&
      nonsensitive(output.files)[1].permissions == "0600" &&
      strcontains(nonsensitive(output.files)[1].content, "secret \"ZmFrZXNlY3JldA==\";") &&
      nonsensitive(output.files)[2].permissions == "0600"
    )
    error_message = "the TSIG key and the request must be 0600 files"
  }
  assert {
    condition     = strcontains(nonsensitive(output.files)[2].content, "update add genesis.demo.example.test. 30 A @NODE_IP@") && strcontains(nonsensitive(output.files)[2].content, "zone example.test.\n")
    error_message = "the zone must get its trailing dot, and the record must take the node IP at boot"
  }
  assert {
    condition     = !strcontains(output.steps[1].commands[0][2], "ZmFrZXNlY3JldA==")
    error_message = "the TSIG secret must not be in the command"
  }
}

run "dns_self_registration_needs_its_server_and_key" {
  command = plan

  variables {
    dns_self_register_zone        = "example.test"
    dns_self_register_record_name = "genesis.demo"
  }

  expect_failures = [var.dns_server_address, var.tsig_key_name, var.tsig_key_secret]
}

run "iscsi_can_be_turned_off" {
  command = plan

  variables {
    iscsi_initiator_enabled = false
  }

  assert {
    condition     = length(output.steps) == 0 && length(nonsensitive(output.files)) == 0
    error_message = "with iSCSI off and no DNS self-registration the module has no step"
  }
}
