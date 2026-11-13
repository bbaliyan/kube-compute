# SPDX-License-Identifier: Apache-2.0
variables {
  dns_zone           = "example.internal."
  record_name        = "api.demo"
  record_addresses   = ["192.0.2.10", "192.0.2.11", "192.0.2.12"]
  dns_server_address = "192.0.2.53"
  tsig_key_name      = "kube-compute"
  tsig_key_algorithm = "hmac-sha256"
  tsig_key_secret    = "ZmFrZXNlY3JldA=="
}

run "disabled_creates_nothing" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = length(terraform_data.this) == 0
    error_message = "enabled = false must create no resource"
  }
  assert {
    condition     = output.record_created == false
    error_message = "record_created must mirror enabled"
  }
}

run "enabled_publishes_one_record_set_under_one_name" {
  command = plan

  assert {
    condition     = length(terraform_data.this) == 1 && output.record_created == true
    error_message = "enabled must create exactly one resource, however many addresses there are"
  }
  assert {
    condition     = terraform_data.this[0].input.record_addresses == tolist(["192.0.2.10", "192.0.2.11", "192.0.2.12"])
    error_message = "every address must go into the one record set"
  }
  assert {
    condition     = output.fqdn == "api.demo.example.internal."
    error_message = "fqdn must be the record name followed by the zone: got ${output.fqdn}"
  }
}

run "the_tsig_secret_stays_out_of_state" {
  command = plan

  assert {
    condition     = !strcontains(jsonencode(terraform_data.this[0].input), nonsensitive(var.tsig_key_secret))
    error_message = "the TSIG secret must not be part of the resource input, which is persisted to state"
  }
}

run "defaults_are_udp_port_53_ttl_300" {
  command = plan

  assert {
    condition = (
      terraform_data.this[0].input.dns_server_port == 53 &&
      terraform_data.this[0].input.record_ttl == 300 &&
      terraform_data.this[0].input.nsupdate_flags == ""
    )
    error_message = "defaults must be port 53, TTL 300 seconds and plain UDP with no nsupdate flag"
  }
}

run "tcp_and_family_map_to_nsupdate_flags" {
  command = plan

  variables {
    dns_transport = "tcp6"
  }

  assert {
    condition     = terraform_data.this[0].input.nsupdate_flags == "-v -6"
    error_message = "tcp6 must force TCP and IPv6: got '${terraform_data.this[0].input.nsupdate_flags}'"
  }
}

run "udp4_pins_the_family_only" {
  command = plan

  variables {
    dns_transport = "udp4"
  }

  assert {
    condition     = terraform_data.this[0].input.nsupdate_flags == "-4"
    error_message = "udp4 must pin IPv4 and not force TCP: got '${terraform_data.this[0].input.nsupdate_flags}'"
  }
}

run "an_unknown_transport_is_rejected" {
  command = plan

  variables {
    dns_transport = "quic"
  }

  expect_failures = [var.dns_transport]
}

run "an_unknown_tsig_algorithm_is_rejected" {
  command = plan

  variables {
    tsig_key_algorithm = "hmac-sha384"
  }

  expect_failures = [var.tsig_key_algorithm]
}

run "a_changed_ttl_is_a_replacement_trigger" {
  command = plan

  variables {
    record_ttl = 60
  }

  assert {
    condition     = contains(terraform_data.this[0].triggers_replace, 60)
    error_message = "a TTL change must be in triggers_replace so nsupdate runs again"
  }
}
