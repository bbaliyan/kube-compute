#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds the release tree for one provider's split repo
# (terraform-<provider>-kube-compute), which the OpenTofu Registry publishes
# as bbaliyan/kube-compute/<provider>.
#
# Usage:
#   release-split.sh <provider> <target_dir> [source_dir]
#       Build the tree into target_dir, a git checkout of the split repo.
#       Everything in it except .git/ and .github/ is replaced.
#   release-split.sh --paths <provider> [source_dir]
#       Print the kube-compute paths the tree is built from, one per line.
#
# The tree is modules/<provider>-cluster at the root, plus every module it
# reaches through `source = "../<module>"`, followed transitively, under
# modules/. The path set is derived, never listed, so a submodule added to or
# retired from the cluster module is picked up by the next release as it is.
#
# A module keeps its name in the split repo, minus the "<provider>-" prefix
# the repo's own name already carries: proxmox-node-pool becomes
# modules/node-pool. Its "../<module>" source lines are the only content
# rewritten, to the module's new relative path.

set -euo pipefail

usage() {
  sed -n '8,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

paths_only=false
if [[ "${1:-}" == "--paths" ]]; then
  paths_only=true
  shift
  [[ $# -ge 1 && $# -le 2 ]] || usage
  provider="$1"
  source_dir="${2:-$(cd "$script_dir/.." && pwd)}"
else
  [[ $# -ge 2 && $# -le 3 ]] || usage
  provider="$1"
  target_dir="$2"
  source_dir="${3:-$(cd "$script_dir/.." && pwd)}"
fi

root_mod="${provider}-cluster"
if [[ ! -d "$source_dir/modules/$root_mod" ]]; then
  echo "error: $source_dir/modules/$root_mod does not exist" >&2
  exit 1
fi

# The module names a module's *.tf files reach with `source = "../<name>"`.
local_deps() {
  grep -hoE '^[[:space:]]*source[[:space:]]*=[[:space:]]*"\.\./[^"/]+"' "$source_dir/modules/$1"/*.tf 2>/dev/null \
    | sed -E 's|.*"\.\./([^"]+)"|\1|' | sort -u || true
}

# Breadth-first from the root module; the root is always first.
modules=("$root_mod")
queue=("$root_mod")
while [[ ${#queue[@]} -gt 0 ]]; do
  mod="${queue[0]}"
  queue=("${queue[@]:1}")
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ ! -d "$source_dir/modules/$dep" ]]; then
      echo "error: modules/$mod references ../$dep, which does not exist" >&2
      exit 1
    fi
    if [[ ! " ${modules[*]} " == *" $dep "* ]]; then
      modules+=("$dep")
      queue+=("$dep")
    fi
  done < <(local_deps "$mod")
done

if $paths_only; then
  printf 'modules/%s\n' "${modules[@]}"
  printf '%s\n' LICENSE NOTICE scripts/release-split.sh
  exit 0
fi

# Where each module lands in the split repo, relative to its root.
declare -A dest
for mod in "${modules[@]}"; do
  if [[ "$mod" == "$root_mod" ]]; then
    dest[$mod]="."
  else
    dest[$mod]="modules/${mod#"${provider}"-}"
  fi
done
if [[ $(printf '%s\n' "${dest[@]}" | sort | uniq -d | wc -l) -ne 0 ]]; then
  echo "error: two modules land on the same path once the ${provider}- prefix is dropped:" >&2
  for mod in "${modules[@]}"; do echo "  modules/$mod -> ${dest[$mod]}" >&2; done
  exit 1
fi

if [[ ! -d "$target_dir/.git" ]]; then
  echo "error: $target_dir is not a git checkout (.git/ missing)" >&2
  exit 1
fi

# .github/ is kept for repo settings the split repo may carry. Everything else
# is this script's output, so a file removed from kube-compute is removed here.
find "$target_dir" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".github" -exec rm -rf {} +

# cp -a rather than rsync, to need nothing the CI image lacks. Lock files are
# kept: this project commits them.
for mod in "${modules[@]}"; do
  mkdir -p "$target_dir/${dest[$mod]}"
  cp -a "$source_dir/modules/$mod/." "$target_dir/${dest[$mod]}/"
done
find "$target_dir" -type d -name ".terraform" -prune -exec rm -rf {} +

# Rewrite each "../<module>" source to where that module now is, relative to
# the module doing the referencing: "./modules/x" from the root, "../x" from a
# sibling under modules/.
for mod in "${modules[@]}"; do
  from="${dest[$mod]}"
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    to="${dest[$dep]}"
    if [[ "$to" == "." ]]; then
      echo "error: modules/$mod references the root module ../$dep" >&2
      exit 1
    fi
    if [[ "$from" == "." ]]; then
      new="./$to"
    else
      new="../${to#modules/}"
    fi
    OLD="../$dep" NEW="$new" perl -pi -e \
      's{^(\s*source\s*=\s*)"\Q$ENV{OLD}\E"}{$1"$ENV{NEW}"}' \
      "$target_dir/$from"/*.tf
  done < <(local_deps "$mod")
done

# Every local source must now resolve inside the tree.
unresolved=0
for mod in "${modules[@]}"; do
  from="$target_dir/${dest[$mod]}"
  while read -r src; do
    [[ -z "$src" ]] && continue
    if [[ ! -d "$from/$src" ]]; then
      echo "error: ${dest[$mod]} has source \"$src\", which does not exist in the tree" >&2
      unresolved=1
    fi
  done < <(grep -hoE '^[[:space:]]*source[[:space:]]*=[[:space:]]*"\.{1,2}/[^"]+"' "$from"/*.tf 2>/dev/null \
    | sed -E 's|.*"([^"]+)"|\1|' || true)
done
[[ "$unresolved" -eq 0 ]] || exit 1

cp "$source_dir/LICENSE" "$source_dir/NOTICE" "$target_dir/"

cat > "$target_dir/.gitignore" <<'EOF'
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
EOF

# The root module's own README is the registry's documentation page; the
# mirror notice goes above it.
root_readme="$source_dir/modules/$root_mod/README.md"
{
  cat <<EOF
> **Release mirror, generated -- do not edit here.** Built from
> [kube-compute](https://github.com/bbaliyan/kube-compute)'s \`modules/${root_mod}\` and the
> modules it uses, on every kube-compute release that changes them. Issues and pull requests
> go to kube-compute. Published on the OpenTofu Registry as \`bbaliyan/kube-compute/${provider}\`.
>
> | Module | Built from |
> |---|---|
EOF
  for mod in "${modules[@]}"; do
    echo "> | \`${dest[$mod]}\` | \`modules/$mod\` |"
  done
  echo
  if [[ -f "$root_readme" ]]; then
    cat "$root_readme"
  fi
} > "$target_dir/README.md"

# variables.tf and outputs.tf must be byte-identical to kube-compute's for
# every module: that is what lets a consumer swap a kube-compute source for
# the split repo's or the registry's without touching its inputs.
parity_fail=0
for mod in "${modules[@]}"; do
  for f in variables.tf outputs.tf; do
    src="$source_dir/modules/$mod/$f"
    dst="$target_dir/${dest[$mod]}/$f"
    if [[ -f "$src" || -f "$dst" ]] && ! cmp -s "$src" "$dst"; then
      echo "interface-parity FAILED: modules/$mod/$f differs in the split tree" >&2
      parity_fail=1
    fi
  done
done
[[ "$parity_fail" -eq 0 ]] || exit 1

echo "release-split: built $target_dir for provider=$provider from $source_dir"
for mod in "${modules[@]}"; do
  echo "  modules/$mod -> ${dest[$mod]}"
done
