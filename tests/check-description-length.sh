#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail when a variable or output description in modules/*/variables.tf or
# modules/*/outputs.tf is longer than 300 characters.
# Usage: check-description-length.sh [max-length [directory...]]   (default 300, modules/)
#
# Why a script: tofu cannot read the descriptions of a module's own variables,
# and tflint is not in the kube-devenv image yet. Perl is in the image and
# reads the quoted strings and heredocs safely.
# The script also fails when a description is in a form it cannot read, so a
# new form cannot hide a long text.
set -euo pipefail

max="${1:-300}"
shift || true
dirs=("${@:-modules}")

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(find "${dirs[@]}" -type f \( -name variables.tf -o -name outputs.tf \) -not -path '*/.terraform/*' | sort)

[[ ${#files[@]} -gt 0 ]] || { echo "description-length: no variables.tf or outputs.tf found"; exit 1; }

perl -CSD -e '
  use strict; use warnings;
  my $max = shift;
  my $status = 0;
  for my $file (@ARGV) {
    open my $fh, "<", $file or die "$file: $!";
    local $/; my $text = <$fh>; close $fh;
    my $attributes = () = $text =~ /^  description\s*=/mg;
    my $read = 0;
    while ($text =~ /^  description\s*=\s*(?:"((?:[^"\x5c]|\x5c.)*)"|<<-?(\w+)\n(.*?)\n[ \t]*\2[ \t]*$)/msg) {
      $read++;
      my ($quoted, $tag, $heredoc) = ($1, $2, $3);
      my $start = $-[0];
      my $body = defined $tag ? $heredoc : $quoted;
      my $line = 1 + (() = substr($text, 0, $start) =~ /\n/g);
      $body =~ s/^[ \t]+//mg if defined $tag;
      my $length = length $body;
      if ($length > $max) { print "$file:$line: description has $length characters, the limit is $max\n"; $status = 1; }
    }
    if ($read != $attributes) { print "$file: read $read of $attributes descriptions; use a quoted string or a heredoc\n"; $status = 1; }
  }
  exit $status;
' "$max" "${files[@]}"
