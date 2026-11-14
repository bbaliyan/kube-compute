# SPDX-License-Identifier: Apache-2.0
# Genesis only. Why this is a script: the signing keys exist only after the API server runs, so
# no plan-time resource can publish them, and the upload must retry until it succeeds. It puts
# the public keys where STS reads them, through the issuer URL.
# The object is write-once: the bucket policy refuses a put that does not send If-None-Match.
# A second put fails because the object exists. That is success, if the issuer serves the object.
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
    if curl -sSf -o /dev/null "$SERVICE_ACCOUNT_ISSUER_URL/keys.json"; then
      PUBLISHED=1
      break
    fi
    sleep 6
  done
  rm -f "$JWKS_FILE"
  if [ "$PUBLISHED" -ne 1 ]; then
    echo "kube-compute: the service account keys were not published and are not served" >&2
    exit 1
  fi
  echo "kube-compute: service account keys published $(date -Is)"
fi
