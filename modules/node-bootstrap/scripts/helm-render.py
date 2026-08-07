#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Render a Helm chart to a manifest string for OpenTofu's `external` data source.

Replaces the `helm template` calls that used to live inside node-bootstrap's
bootstrap-runner.sh wrapper (executed by a null_resource local-exec). Running
it as an `external` data source instead means the render happens at PLAN time,
is side-effect-free, and its result is a plan-known string — which is what lets
the whole cloud-init payload be asserted on with `command = plan` in tofu test.

Contract (OpenTofu `external` provider protocol): a single JSON object on
stdin, all values strings; a single flat JSON object of strings on stdout.

    stdin : {"release","chart","repo","version","namespace","values_b64"}
    stdout: {"manifest": "<rendered yaml>"}

`helm template` needs the helm binary and network access to the chart repo but
no cluster access, which is why this can run on the operator machine.
"""
import base64
import json
import subprocess
import sys
import tempfile

REQUIRED = ("release", "chart", "repo", "version", "namespace", "values_b64")


def main() -> int:
    try:
        query = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print("helm-render: invalid JSON on stdin: %s" % exc, file=sys.stderr)
        return 1

    missing = [k for k in REQUIRED if k not in query]
    if missing:
        print("helm-render: missing query keys: %s" % ", ".join(missing), file=sys.stderr)
        return 1

    values = base64.b64decode(query["values_b64"])
    with tempfile.NamedTemporaryFile(suffix=".yaml", delete=True) as values_file:
        values_file.write(values)
        values_file.flush()
        cmd = [
            "helm", "template",
            query["release"], query["chart"],
            "--repo", query["repo"],
            "--version", query["version"],
            "--namespace", query["namespace"],
            "--include-crds",
            "-f", values_file.name,
        ]
        try:
            completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except FileNotFoundError:
            print("helm-render: the 'helm' binary is not on PATH", file=sys.stderr)
            return 1

    if completed.returncode != 0:
        print("helm-render: %s failed:\n%s" % (" ".join(cmd), completed.stderr), file=sys.stderr)
        return 1

    json.dump({"manifest": completed.stdout}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
