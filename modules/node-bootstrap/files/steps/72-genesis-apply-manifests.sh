# SPDX-License-Identifier: Apache-2.0
# The genesis-apply list is a generic mechanism: this step does not interpret the content,
# it only applies the manifests in order. A genesis node that rejoined an existing cluster
# is a joining server by now and applies nothing.
# Polls for something the platform Application installs. On a dedicated control plane that
# first needs a worker to join and run Argo CD, hence the long ceiling.
PLATFORM_WAIT_SECONDS=1800
wait_until() {
  local what=$1 deadline=$((SECONDS + PLATFORM_WAIT_SECONDS))
  shift
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "kube-compute: gave up after ${PLATFORM_WAIT_SECONDS}s waiting for $what" >&2
      return 1
    fi
    sleep 5
  done
}
if [ "$NODE_ROLE" = "server-init" ]; then
  # Unquoted on purpose: this is a space-separated list that must word-split. The module
  # guarantees no path contains whitespace.
  # shellcheck disable=SC2086
  for manifest_path in $GENESIS_APPLY_MANIFESTS; do
    wait_until "$manifest_path to apply" $KUBECTL apply -f "$manifest_path" || { $KUBECTL apply -f "$manifest_path"; exit 1; }
  done
fi
