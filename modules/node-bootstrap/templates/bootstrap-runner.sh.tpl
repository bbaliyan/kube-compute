#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Shared bootstrap runner for BOTH invocation modes. The Cilium/Argo genesis
# render and the extra-vars payload are identical across modes — the whole
# point of factoring this into one template is that those never diverge again.
# Only the plumbing differs: operator_connect installs collections and connects
# to the node; on_node installs ansible-core, unpacks the role bundle, and runs
# against localhost. Rendered by templatefile: a dollar-brace is Terraform
# interpolation; a doubled dollar-brace escapes to a literal for bash.
set -euo pipefail

%{ if mode == "operator_connect" ~}
# --- operator_connect: ansible runs HERE (operator), connects to the node ---
# Mirror everything to a local logfile the operator can `tail -f` — Terraform
# suppresses this provisioner's own console output because the resource config
# touches sensitive values. Ansible's own output is already secret-safe
# (no_log on every secret-touching task).
BOOTSTRAP_LOG="/tmp/kube-compute-bootstrap-${node_name}.log"
exec > >(tee "$BOOTSTRAP_LOG") 2>&1
echo "kube-compute: bootstrap log for ${node_name} -> $BOOTSTRAP_LOG"
# Force a locale Ansible/Python can always initialize regardless of what the
# calling shell forwards in.
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# Collections/Python deps are playbook-specific, not baked into kube-devenv.
# Both are no-ops once the pinned version is present.
ansible-galaxy collection install -r "${requirements_yml}"
pip3 install --quiet --break-system-packages -r "${requirements_txt}"
PLAYBOOK="${playbook_path}"
HELM="helm"
INVENTORY_ARGS=(-i '${node_name},')
%{ else ~}
# --- on_node: ansible runs ON THIS NODE, delivered via az vm run-command ---
# Secrets arrive as run-command protected parameters, injected as environment
# variables with the same names operator_connect's local-exec environment block
# uses (CLUSTER_TOKEN, CLUSTER_AGENT_TOKEN, AGENT_TOKEN_FETCH_COMMAND,
# TRUSTED_CA_PEM) — the role reads them identically. The bundle carries NO
# secrets.
# AlmaLinux 10 ships ansible-core in AppStream (no EPEL/pip). The role is pure
# ansible.builtin under -c local, so no Galaxy collections are needed.
dnf install -y ansible-core
WORKDIR="$(mktemp -d)"
# python3 is guaranteed on the AlmaLinux cloud image; use its zipfile module so
# the node needs no unzip/tar tooling to unpack the role bundle.
python3 - "$WORKDIR" <<'KUBE_COMPUTE_UNPACK_EOF'
import base64, io, sys, zipfile
zipfile.ZipFile(io.BytesIO(base64.b64decode("""${bundle_zip_b64}"""))).extractall(sys.argv[1])
KUBE_COMPUTE_UNPACK_EOF
PLAYBOOK="$WORKDIR/${bundle_playbook_relpath}"
# Transient helm for the genesis render — downloaded for this one call and
# deleted after, no persistent footprint (the node never installs helm).
HELM_TMP="$(mktemp -d)"
arch="$(uname -m)"; case "$arch" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
curl -sfL "https://get.helm.sh/helm-v4.2.2-linux-$arch.tar.gz" | tar -xz -C "$HELM_TMP"
HELM="$HELM_TMP/linux-$arch/helm"
INVENTORY_ARGS=(-i 'localhost,' -c local)
%{ endif ~}

# --- shared: render Cilium/Argo genesis manifests (server-init only) ---
# The role's copy tasks read these from the control machine — which is the
# operator in operator_connect and the node itself in on_node — so rendering
# to /tmp here works unchanged for both. `helm template` needs no cluster
# access, only chart + values.
%{ if cni == "cilium" && node_role == "server-init" ~}
CILIUM_VALUES="$(mktemp)"
echo "${cilium_values_b64}" | base64 -d >"$CILIUM_VALUES"
"$HELM" template cilium cilium --repo https://helm.cilium.io/ --version "${cilium_version}" --namespace kube-system --include-crds -f "$CILIUM_VALUES" >"/tmp/kube-compute-cilium-manifest-${node_name}.yaml"
rm -f "$CILIUM_VALUES"
%{ endif ~}
%{ if argocd_needed != "" && node_role == "server-init" ~}
ARGOCD_VALUES="$(mktemp)"
echo "${argocd_values_b64}" | base64 -d >"$ARGOCD_VALUES"
{
  echo "apiVersion: v1"
  echo "kind: Namespace"
  echo "metadata:"
  echo "  name: argocd"
  echo "---"
  "$HELM" template argocd argo-cd --repo https://argoproj.github.io/argo-helm --version "${argocd_version}" --namespace argocd --include-crds -f "$ARGOCD_VALUES"
} >"/tmp/kube-compute-argocd-manifest-${node_name}.yaml"
rm -f "$ARGOCD_VALUES"
%{ endif ~}

# --- shared: write non-secret extra-vars, run the play ---
EXTRA_VARS_FILE="$(mktemp)"
trap 'rm -f "$EXTRA_VARS_FILE"' EXIT
cat >"$EXTRA_VARS_FILE" <<'KUBE_COMPUTE_EXTRA_VARS_EOF'
${extra_vars_json}
KUBE_COMPUTE_EXTRA_VARS_EOF
ansible-playbook "$${INVENTORY_ARGS[@]}" -e "@$EXTRA_VARS_FILE" "$PLAYBOOK"
