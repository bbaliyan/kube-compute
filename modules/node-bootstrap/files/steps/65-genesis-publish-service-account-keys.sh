# SPDX-License-Identifier: Apache-2.0
# Genesis only. Why this is a script: the signing keys exist only after the API server runs, so
# no plan-time resource can publish them, and the upload must retry until it succeeds. It puts
# the public keys where STS reads them, through the issuer URL.
# The object is write-once: the bucket policy refuses a put that does not send If-None-Match.
# A second put fails because the object exists. That is success only if the issuer serves every
# key ID (kid) of the local keys. If the cluster signing key changed, the served keys are stale.
# The image has no jq, so key IDs are read with grep and sed.
kube_compute_kids() {
  grep -o '"kid" *: *"[^"]*"' "$1" | sed 's/.*: *"\(.*\)"$/\1/' | sort -u
}

# Returns 0 if every local kid is served, 1 if one is missing, 2 if keys.json is not served yet.
kube_compute_served_keys_match() {
  served=$(mktemp)
  if ! curl -sSf -o "$served" "$SERVICE_ACCOUNT_ISSUER_URL/keys.json"; then
    rm -f "$served"
    return 2
  fi
  served_kids=$(kube_compute_kids "$served")
  rm -f "$served"
  local_kids=$(kube_compute_kids "$JWKS_FILE")
  [ -n "$local_kids" ] || return 1
  for kid in $local_kids; do
    printf '%s\n' "$served_kids" | grep -qxF "$kid" || return 1
  done
}

if [ "$NODE_ROLE" = "server-init" ] && [ -n "${SERVICE_ACCOUNT_KEYS_BUCKET:-}" ]; then
  JWKS_FILE=/run/service-account-jwks.json
  $KUBECTL get --raw /openid/v1/jwks >"$JWKS_FILE"
  PUBLISHED=0
  for _ in $(seq 1 10); do
    if aws s3api put-object --bucket "$SERVICE_ACCOUNT_KEYS_BUCKET" --key keys.json --body "$JWKS_FILE" \
      --content-type application/json --if-none-match '*' --region "$SERVICE_ACCOUNT_KEYS_REGION" >/dev/null; then
      PUBLISHED=1
      break
    fi
    kube_compute_served_keys_match
    case $? in
      0)
        PUBLISHED=1
        break
        ;;
      1)
        rm -f "$JWKS_FILE"
        echo "kube-compute: keys.json exists but does not hold the cluster signing key. The cluster signing key changed. Remove keys.json from the bucket or recreate the bucket." >&2
        exit 1
        ;;
    esac
    sleep 6
  done
  rm -f "$JWKS_FILE"
  if [ "$PUBLISHED" -ne 1 ]; then
    echo "kube-compute: the service account keys were not published and are not served" >&2
    exit 1
  fi
  echo "kube-compute: service account keys published $(date -Is)"
fi
