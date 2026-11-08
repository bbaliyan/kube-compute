#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Starts, stops or names the AWS emulator for the state-migration check.
# Usage: emulator.sh <moto|fakecloud> <start|stop|endpoint>
# Each emulator has one file in emulators/ that sets its binary and its
# environment. Run this where the emulator is installed, not in the devenv
# image: the image has no emulator.
set -euo pipefail

name=${1:?usage: emulator.sh <moto|fakecloud> <start|stop|endpoint>}
action=${2:?usage: emulator.sh <moto|fakecloud> <start|stop|endpoint>}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

SM_EMULATOR_PORT=${SM_EMULATOR_PORT:-4566}
SM_EMULATOR_LOG=${SM_EMULATOR_LOG:-/tmp/state-migration-$name.log}
# shellcheck source=/dev/null
source "$here/emulators/$name.sh"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$SM_EMULATOR_PORT") 2>/dev/null; }

case $action in
endpoint) echo "http://127.0.0.1:$SM_EMULATOR_PORT" ;;
stop)
  # Stop every known emulator: another one can hold the port.
  for file in "$here"/emulators/*.sh; do (source "$file"; emulator_stop) || true; done
  for _ in $(seq 60); do port_open || exit 0; sleep 0.5; done
  echo "emulator.sh: port $SM_EMULATOR_PORT is still in use after 30 seconds. Another program holds it." >&2
  echo "Find it with: ss -ltnp 'sport = :$SM_EMULATOR_PORT'. Or set SM_EMULATOR_PORT to a free port." >&2
  exit 1
  ;;
start)
  "$0" "$name" stop
  emulator_start
  for _ in $(seq 60); do port_open && exit 0; sleep 0.5; done
  echo "emulator.sh: $name did not open port $SM_EMULATOR_PORT; see $SM_EMULATOR_LOG" >&2
  exit 1
  ;;
*) echo "emulator.sh: unknown action $action" >&2; exit 2 ;;
esac
