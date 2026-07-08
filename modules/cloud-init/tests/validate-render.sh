#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Renders cloud-init (server-init and worker roles) and validates the
# YAML + embedded bash for each. State is written to /tmp so each run starts
# from scratch and the working tree stays clean (idempotent CI gate).
set -euo pipefail
cd "$(dirname "$0")"

check_render() {
  local fixture_dir="$1" state_name="$2"
  (
    cd "fixtures/${fixture_dir}"
    STATE="/tmp/kube-compute-render-check-${state_name}.tfstate"
    tofu init -backend=false >/dev/null
    tofu apply -auto-approve -state="$STATE" >/dev/null
    tofu output -state="$STATE" -raw cloud_init >"/tmp/kube-compute-ci-${state_name}.yaml"
  )

  python3 -c "import yaml; yaml.safe_load(open('/tmp/kube-compute-ci-${state_name}.yaml'))"
  echo "OK: ${fixture_dir} cloud-init is valid YAML"

  python3 - "$state_name" <<'PY'
import sys, yaml
state_name = sys.argv[1]
doc = yaml.safe_load(open(f"/tmp/kube-compute-ci-{state_name}.yaml"))
script = next(f["content"] for f in doc["write_files"]
              if f["path"] == "/usr/local/bin/kube-compute-bootstrap.sh")
open(f"/tmp/kube-compute-bootstrap-{state_name}.sh", "w").write(script)
PY
  bash -n "/tmp/kube-compute-bootstrap-${state_name}.sh"
  echo "OK: ${fixture_dir} embedded bootstrap script passes bash -n"
}

check_render "render-check" "server-init"
check_render "render-check-worker" "worker"
