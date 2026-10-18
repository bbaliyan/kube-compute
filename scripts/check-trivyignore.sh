#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Fail when a .trivyignore entry has no exp:YYYY-MM-DD date or the date has
# passed. Usage: check-trivyignore.sh [file]   (default .trivyignore)
set -euo pipefail

file="${1:-.trivyignore}"
today="${TODAY:-$(date +%F)}"
status=0

while IFS= read -r line; do
  [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
  if [[ ! "$line" =~ exp:([0-9]{4}-[0-9]{2}-[0-9]{2})([[:space:]]|$) ]]; then
    echo "trivyignore: entry has no valid exp:YYYY-MM-DD date: ${line%% *}"
    status=1
  elif [[ "${BASH_REMATCH[1]}" < "$today" ]]; then
    echo "trivyignore: entry expired on ${BASH_REMATCH[1]}: ${line%% *}"
    status=1
  fi
done <"$file"

exit "$status"
