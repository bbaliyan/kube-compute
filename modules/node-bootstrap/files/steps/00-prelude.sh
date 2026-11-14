#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Runtime half of the RKE2 bootstrap. The image bakes the OS, the RKE2 binaries and the
# tools. This program holds what only this node can do: join logic and the genesis steps.
#
# Terraform joins the step files in this directory that apply to the node's role, and
# cloud-init writes the result to /opt/kube-compute/bootstrap.sh with its comment lines
# removed to save space. A step that does not apply to the role is never in the file.
# Per-cluster values reach the program as data, in node.env. A heredoc body in a step
# must never start with "#", because the comment strip would remove that line.
#
# Why each step is a script and not cloud-init or an RKE2 manifest. cloud-init runs a list
# of commands once, in order, and cannot branch on what a command found or wait for a
# condition. Every step below needs one of these:
#   - A fact only the booted node has: its IP for node-ip and tls-san (20-node-config-*).
#   - A choice made from live cluster state. The rejoin probe (10) decides whether this node
#     starts a new etcd cluster or joins a live one, and may change NODE_ROLE. The steps
#     that apply to the genesis node only (30, 40, 41, 50, 70, 71) run after that choice.
#     The skew checks (01, 31) compare the image with a running API server.
#   - A retry or a wait. A joining server wipes its local state and retries when etcd
#     refuses a second learner (51). The readiness waits (60, 61) and the CoreDNS wait
#     before Argo CD (71) poll until the cluster is ready, so a log line means success.
#   - An ordering that cloud-init cannot hold: the Cilium render comes from the platform
#     ref cloned at boot (30, 40), and RKE2 reads server/manifests only at its first start.
# The service starts (50, 52) and the cleanup (99) are here so that they run in that order,
# after the steps above. Declarative work is not here: files, the trusted CA and the
# package settings are cloud-init write_files and runcmd entries.

set -euo pipefail
exec > >(tee -a /var/log/kube-compute-bootstrap.log) 2>&1
echo "kube-compute: bootstrap start $(date -Is)"

# A cloud-init command that failed before this program leaves this marker, because
# runcmd does not stop at a failed command. Stop here, so the boot fails.
if [ -e /run/kube-compute-step-failed ]; then
  echo "kube-compute: a step before the boot program failed; see /var/log/cloud-init-output.log" >&2
  exit 1
fi
rm -f /run/kube-compute-boot-complete

MISSING_TOOLS=""
for tool in git curl getent ip awk systemctl; do
  command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -n "$MISSING_TOOLS" ]; then
  echo "kube-compute: the image lacks these tools:$MISSING_TOOLS" >&2
  exit 1
fi

KC=/opt/kube-compute
# shellcheck disable=SC1091
. "$KC/node.env"

# containerd's TLS pin in registries.yaml points at this file, so a node without the CA
# cannot pull images. cloud-init writes the file, or the image bakes it.
if [ -n "$TRUSTED_CA_FILE" ]; then
  if [ ! -s "$TRUSTED_CA_FILE" ]; then
    echo "kube-compute: no trusted CA at $TRUSTED_CA_FILE" >&2
    exit 1
  fi
  command -v update-ca-trust >/dev/null 2>&1 || { echo "kube-compute: the image lacks update-ca-trust" >&2; exit 1; }
fi

KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
PLATFORM_DIR=/run/platform-ref

# RKE2 needs the node's own IP for node-ip and, on a server, for tls-san.
NODE_IP="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
if [ -z "$NODE_IP" ]; then
  echo "kube-compute: could not determine this node's IP" >&2
  exit 1
fi
