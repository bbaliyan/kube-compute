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

## Regenerating the docs

The Inputs and Outputs tables in each module README come from the `.tf` files. They sit between the
`<!-- BEGIN_TF_DOCS -->` and `<!-- END_TF_DOCS -->` markers. Do not edit them by hand.

1. After you change a variable or an output, run `make docs`.
2. Commit the changed README files.

If the tables are stale, `make docs-check` fails and tells you to run `make docs`. `make test-commit`
runs `make docs-check`.

## Conventions

- OpenTofu: run `tofu fmt` before committing.
- Every source file carries `# SPDX-License-Identifier: Apache-2.0`.

## Examples

`examples/` holds one minimal call for each cluster module. Every value is a
placeholder. `make validate` runs `tofu validate` on each one. Keep them valid
when you change a required input.

## Versions and release notes

- A release is a tag `vX.Y.Z` on `main`. The release workflow publishes it to the
  provider mirrors, with notes built from the commits since the last release.
  There is no CHANGELOG file. The commit subject is the release note.
  Before it publishes, the workflow builds each provider's tree and runs
  `make validate-tree` on a copy of it. That runs `tofu fmt -check`, `tofu init`,
  `tofu validate` and every `tofu test` file in the root module and in each module
  under `modules/`. One failure stops the release for that provider.
- The version is 0.x. A breaking change raises the minor number. Any other change
  raises the patch number.
- A change is breaking if it removes or renames a module, an input or an output,
  changes a default, adds an input that has no default, changes the type of an
  input or an output, makes a validation stricter, or forces a node to be replaced.
- Mark a breaking commit with `!`, as in `feat!:` or `refactor!:`, and say in the
  body what a user must change.
- Clusters are disposable. A release can change resource addresses or replace
  resources, and an upgrade is a rebuild. The module keeps no state compatibility
  between releases.
