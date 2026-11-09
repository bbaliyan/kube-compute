# SPDX-License-Identifier: Apache-2.0
# The bootstrap program travels in user data with its comment lines removed.
# The strip is a regex over lines, so it would also remove a line of a heredoc
# body that starts with "#". These tests fail if the program ever has one.

variables {
  cluster_name        = "test"
  node_name           = "test-cp-0"
  node_role           = "server-init"
  cluster_token       = "SUPERSECRETTOKEN123"
  cluster_agent_token = "SUPERSECRETAGENT456"
}

run "heredoc_bodies_have_no_comment_looking_lines" {
  command = plan

  assert {
    condition     = length(regexall("<<", local.bootstrap_program)) == length(regexall("<<EOF\n", local.bootstrap_program))
    error_message = "every heredoc in bootstrap.sh must use the EOF delimiter, so this test can find the bodies"
  }
  assert {
    condition     = length(regexall("<<EOF\n", local.bootstrap_program)) > 0
    error_message = "the heredoc scan found no heredoc, so it checks nothing"
  }
  assert {
    condition = alltrue([
      for body in regexall("(?s)<<EOF\n(.*?)\nEOF\n", local.bootstrap_program) :
      length(regexall("(?m)^[ \t]*#", body[0])) == 0
    ])
    error_message = "a heredoc body line in bootstrap.sh starts with '#', and the comment strip would remove it. Reword the line."
  }
}

run "strip_keeps_the_shebang_and_code" {
  command = plan

  assert {
    condition     = startswith(local.bootstrap_program_inline, "#!/usr/bin/env bash\n")
    error_message = "the shebang must survive the comment strip"
  }
  assert {
    condition     = length(regexall("(?m)^[ \t]*#", replace(local.bootstrap_program_inline, "#!/usr/bin/env bash\n", ""))) == 0
    error_message = "no comment-only line may reach user data"
  }
  assert {
    condition     = length(regexall("(?m)^[ \t]*[^# \t\n]", local.bootstrap_program_inline)) == length(regexall("(?m)^[ \t]*[^# \t\n]", replace(local.bootstrap_program, "/(?m)^[ \t]*#.*\n/", "")))
    error_message = "the strip must remove comment-only lines and no code line"
  }
  assert {
    condition     = length(local.bootstrap_program_inline) < length(local.bootstrap_program)
    error_message = "the strip must make the program smaller"
  }
}

run "no_self_hash_remains" {
  command = plan

  assert {
    condition     = !strcontains(local.bootstrap_program, "KUBE_BOOTSTRAP_SHA256") && !strcontains(local.bootstrap_program, "sha256sum \"$0\"")
    error_message = "bootstrap.sh must not hash itself"
  }
}
