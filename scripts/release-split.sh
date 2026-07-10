#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds a squashed release tree for one provider's split repo
# (terraform-<provider>-kube-compute) from the current kube-compute checkout.
#
# Usage: release-split.sh <provider> <target_dir> [source_dir]
#
#   provider    e.g. proxmox, aws, azure
#   target_dir  path to a checkout of the split repo (its .git/ is preserved;
#               everything else is wiped except the exclude-list below)
#   source_dir  path to the kube-compute checkout to copy from (default: repo
#               root, derived from this script's own location)
#
# Path-set copied in: component-versions, cloud-init, control-plane-<provider>
# (becomes the split repo's root module), node-pool-<provider> (nests under
# modules/).
#
# Only control-plane-<provider>/main.tf's "../cloud-init" and
# "../component-versions" source lines are rewritten (sibling -> parent-child,
# since control-plane-<provider> moves from being a sibling of those two
# modules to being their parent in the split repo). No other content differs
# between source and output.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 <provider> <target_dir> [source_dir]" >&2
  exit 1
fi

provider="$1"
target_dir="$2"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="${3:-$(cd "$script_dir/.." && pwd)}"

control_plane_mod="control-plane-${provider}"
node_pool_mod="node-pool-${provider}"

for mod in "$control_plane_mod" "$node_pool_mod" component-versions cloud-init; do
  if [[ ! -d "$source_dir/modules/$mod" ]]; then
    echo "error: $source_dir/modules/$mod does not exist" >&2
    exit 1
  fi
done

if [[ ! -d "$target_dir/.git" ]]; then
  echo "error: $target_dir is not a git checkout (.git/ missing)" >&2
  exit 1
fi

# ---- Wipe target, preserving .git/ and the exclude-list ----
# Exclude-list: README.md (static, hand-written per split repo) and .github/
# (repo settings only, no CI of its own). Never overwritten by a release.
find "$target_dir" -mindepth 1 -maxdepth 1 \
  ! -name ".git" ! -name "README.md" ! -name ".github" \
  -exec rm -rf {} +

# ---- Copy control-plane-<provider> to the split repo root ----
# rsync excludes local tofu-init artifacts (.terraform/) that must never leave
# a developer checkout; .terraform.lock.hcl IS copied (committed per CLAUDE.md).
mkdir -p "$target_dir"
rsync -a --exclude='.terraform/' "$source_dir/modules/$control_plane_mod/" "$target_dir/"

# ---- Copy the rest under modules/<name>/ ----
mkdir -p "$target_dir/modules"
for mod in "$node_pool_mod" cloud-init component-versions; do
  mkdir -p "$target_dir/modules/$mod"
  rsync -a --exclude='.terraform/' "$source_dir/modules/$mod/" "$target_dir/modules/$mod/"
done

# ---- Rewrite the root module's known relative references to cloud-init /
# component-versions ----
# Scoped find/replace only — not a general HCL rewrite. Two forms exist in
# control-plane-<provider>/main.tf: the module "source" lines, and a
# path.module-relative default (coalesce(var.cloud_init_template,
# "${path.module}/../cloud-init/...")) used to locate the bundled template
# file when the consumer doesn't override it.
main_tf="$target_dir/main.tf"
if [[ ! -f "$main_tf" ]]; then
  echo "error: $main_tf missing after copy" >&2
  exit 1
fi
perl -pi -e 's{source\s*=\s*"\.\./cloud-init"}{source = "./modules/cloud-init"}g;
             s{source\s*=\s*"\.\./component-versions"}{source = "./modules/component-versions"}g;
             s{\$\{path\.module\}/\.\./cloud-init}{\${path.module}/modules/cloud-init}g;
             s{\$\{path\.module\}/\.\./component-versions}{\${path.module}/modules/component-versions}g;' \
  "$main_tf"

# ---- Copy LICENSE/NOTICE verbatim (not on the exclude-list) ----
cp "$source_dir/LICENSE" "$target_dir/LICENSE"
cp "$source_dir/NOTICE" "$target_dir/NOTICE"

# ---- Interface-parity check ----
# variables.tf/outputs.tf must be byte-identical between source and output
# for every copied module — this is what lets a consumer swap a git/local
# source for the registry source with zero change to their inputs block.
parity_fail=0
check_parity() {
  local name="$1" src="$2" dst="$3"
  for f in variables.tf outputs.tf; do
    if [[ -f "$src/$f" || -f "$dst/$f" ]]; then
      if ! diff -q "$src/$f" "$dst/$f" >/dev/null 2>&1; then
        echo "interface-parity FAILED: $name/$f differs between source and split-repo output" >&2
        parity_fail=1
      fi
    fi
  done
}
check_parity "$control_plane_mod" "$source_dir/modules/$control_plane_mod" "$target_dir"
check_parity "$node_pool_mod" "$source_dir/modules/$node_pool_mod" "$target_dir/modules/$node_pool_mod"
check_parity "cloud-init" "$source_dir/modules/cloud-init" "$target_dir/modules/cloud-init"
check_parity "component-versions" "$source_dir/modules/component-versions" "$target_dir/modules/component-versions"

if [[ "$parity_fail" -ne 0 ]]; then
  echo "error: interface-parity check failed — see above" >&2
  exit 1
fi

echo "release-split: built $target_dir for provider=$provider from $source_dir"
