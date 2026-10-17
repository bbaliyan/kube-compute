# Contributing

## Developer Certificate of Origin (DCO)

Every commit must be signed off, certifying you have the right to submit it under
the project's Apache-2.0 license:

    git commit -s -m "your message"

This adds a `Signed-off-by: Your Name <you@example.com>` line. PRs with unsigned
commits are blocked by CI. The same check rejects AI-attribution lines
(`Co-Authored-By`, `Generated with`) in commit messages.

## Checks

Run `make test-commit` inside the kube-devenv image. CI runs the same target. Run
`make hooks` once to run the fast subset (`make test-fast`) before each commit.

## Conventions

- OpenTofu: run `tofu fmt` before committing.
- Every source file carries `# SPDX-License-Identifier: Apache-2.0`.
