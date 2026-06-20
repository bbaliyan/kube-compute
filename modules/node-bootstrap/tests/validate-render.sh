#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Renders node-bootstrap (all features) and validates the YAML + embedded bash.
# State is written to /tmp so each run starts from scratch and the working
# tree stays clean (idempotent CI gate).
set -euo pipefail
cd "$(dirname "$0")/../examples/render-check"

STATE=/tmp/kube-node-render-check.tfstate

tofu init -backend=false >/dev/null
tofu apply -auto-approve -state="$STATE" >/dev/null
tofu output -state="$STATE" -raw cloud_init >/tmp/kube-node-ci.yaml

# 1. The whole document must be valid YAML.
python3 -c 'import yaml; yaml.safe_load(open("/tmp/kube-node-ci.yaml"))'
echo "OK: cloud-init is valid YAML"

# 2. The embedded bootstrap script must be syntactically valid bash.
python3 - <<'PY'
import yaml
doc = yaml.safe_load(open("/tmp/kube-node-ci.yaml"))
script = next(f["content"] for f in doc["write_files"]
              if f["path"] == "/usr/local/bin/kube-node-bootstrap.sh")
open("/tmp/kube-node-bootstrap.sh", "w").write(script)
PY
bash -n /tmp/kube-node-bootstrap.sh
echo "OK: embedded bootstrap script passes bash -n"
