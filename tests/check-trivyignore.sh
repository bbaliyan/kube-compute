#!/usr/bin/env bash
# Tests for scripts/check-trivyignore.sh.
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/scripts/check-trivyignore.sh"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

expect() {
  local want="$1" name="$2" content="$3"
  printf '%s\n' "$content" >"$dir/ignore"
  local got=0
  TODAY=2026-10-18 "$script" "$dir/ignore" >/dev/null || got=$?
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: exit $got, want $want"
    exit 1
  fi
  echo "ok   $name"
}

expect 0 "entry with a future expiry" "AVD-AWS-0104 exp:2027-07-07 reason:x"
expect 0 "comments and blank lines" $'# note\n\nAVD-AWS-0104 exp:2027-07-07 reason:x'
expect 1 "entry without an expiry" "AVD-AWS-0104 reason:x"
expect 1 "entry with an expired date" "AVD-AWS-0104 exp:2026-01-01 reason:x"
expect 1 "entry with a malformed date" "AVD-AWS-0104 exp:soon reason:x"
