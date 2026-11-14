# SPDX-License-Identifier: Apache-2.0
# This drop-in holds what only the node knows: its own IP and the agent token. The token
# is either in secrets.env or read here from SSM Parameter Store with the node role.
# shellcheck disable=SC1091
. "$KC/secrets.env"
if [ -n "${AGENT_TOKEN_SSM_PARAMETER:-}" ]; then
  RESOLVED_AGENT_TOKEN="$(aws ssm get-parameter --name "$AGENT_TOKEN_SSM_PARAMETER"     --with-decryption --query Parameter.Value --output text --region "$AGENT_TOKEN_SSM_REGION")"
else
  RESOLVED_AGENT_TOKEN="${AGENT_TOKEN:-}"
fi
if [ -z "$RESOLVED_AGENT_TOKEN" ]; then
  echo "kube-compute: the agent token is empty" >&2
  exit 1
fi
# A double-quoted YAML scalar: escape the backslash first, then the double quote.
QUOTED_AGENT_TOKEN="${RESOLVED_AGENT_TOKEN//\\/\\\\}"
QUOTED_AGENT_TOKEN="${QUOTED_AGENT_TOKEN//\"/\\\"}"
install -d -m 0755 /etc/rancher/rke2/config.yaml.d
umask 077
{
  echo "node-ip: $NODE_IP"
  echo "token: \"$QUOTED_AGENT_TOKEN\""
} >/etc/rancher/rke2/config.yaml.d/20-node.yaml
umask 022
