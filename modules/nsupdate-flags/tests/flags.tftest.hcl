# SPDX-License-Identifier: Apache-2.0
run "udp_needs_no_flag" {
  command = plan

  variables {
    transport = "udp"
  }

  assert {
    condition     = output.flags == ""
    error_message = "plain UDP is nsupdate's default and needs no flag"
  }
}

run "tcp_forces_tcp" {
  command = plan

  variables {
    transport = "tcp"
  }

  assert {
    condition     = output.flags == "-v"
    error_message = "tcp must pass -v"
  }
}

run "tcp4_forces_tcp_and_ipv4" {
  command = plan

  variables {
    transport = "tcp4"
  }

  assert {
    condition     = output.flags == "-v -4"
    error_message = "tcp4 must pass -v and -4"
  }
}

run "udp6_pins_ipv6" {
  command = plan

  variables {
    transport = "udp6"
  }

  assert {
    condition     = output.flags == "-6"
    error_message = "udp6 must pass -6 and no -v"
  }
}

run "an_unknown_transport_is_rejected" {
  command = plan

  variables {
    transport = "sctp"
  }

  expect_failures = [var.transport]
}
