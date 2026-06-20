#cloud-config
# K3s node bootstrap — rendered by node-bootstrap. Provider-agnostic.
# Status is written to a local file and read out-of-band by the control-plane
# verb-scripts (no inbound port). Stage sequence is fixed; optional stages emit
# their status line even when their body is skipped.
write_files:
  - path: /etc/kube-node/env
    permissions: "0640"
    owner: root:root
    content: |
      CLUSTER_NAME="${cluster_name}"
      K8S_VERSION="${k8s_version}"
      CLUSTER_FQDN="${cluster_fqdn == null ? "" : cluster_fqdn}"

%{ if trusted_ca_pem != null ~}
  - path: /etc/pki/ca-trust/source/anchors/trusted-ca.crt
    permissions: "0644"
    owner: root:root
    encoding: b64
    content: ${base64encode(trusted_ca_pem)}
%{ endif ~}
%{ if registry_mirror_url != null ~}
  - path: /etc/rancher/k3s/registries.yaml
    permissions: "0644"
    owner: root:root
    content: |
      mirrors:
        docker.io:
          endpoint: ["${registry_mirror_url}"]
        ghcr.io:
          endpoint: ["${registry_mirror_url}"]
        quay.io:
          endpoint: ["${registry_mirror_url}"]
        registry.k8s.io:
          endpoint: ["${registry_mirror_url}"]
%{ endif ~}
  - path: /usr/local/bin/kube-node-bootstrap.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      source /etc/kube-node/env

      STATUS_FILE=/var/log/kube-node/bootstrap-status
      KUBECONFIG_OUT=/var/lib/kube-node/kubeconfig
      mkdir -p "$(dirname "$STATUS_FILE")" "$(dirname "$KUBECONFIG_OUT")"
      status() { echo "$1" >"$STATUS_FILE"; echo "[bootstrap] $1"; }

      # Provider-neutral node IP discovery via the default-route source address.
      NODE_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
      [ -n "$NODE_IP" ] || { status "FAILED:no-node-ip"; exit 1; }

      status "stage-1:os-trust"
      %{ if trusted_ca_pem != null ~}
      update-ca-trust extract
      %{ endif ~}

      status "stage-2:registry-mirror"
      # (registry mirror body added in a later task; no-op when no mirror is set.)

      status "stage-3:selinux-prep"
      # RHEL-family: install the k3s SELinux policy so K3s is not blocked.
      # Best-effort with retry on RPM lock; never hard-fail (per-EL availability varies).
      if command -v dnf >/dev/null 2>&1; then
        dnf makecache -y || true
        for a in 1 2 3 4 5; do
          dnf install -y k3s-selinux && break
          if [ "$a" = 5 ]; then
            echo "[bootstrap] WARN: k3s-selinux not installed after retries" >&2
            break
          fi
          sleep 10; pkill -x dnf 2>/dev/null || true; pkill -x rpm 2>/dev/null || true
        done
      fi

      status "stage-4:k8s-install"
      TLS_SANS="--tls-san $NODE_IP"
      [ -n "$CLUSTER_FQDN" ] && TLS_SANS="$TLS_SANS --tls-san $CLUSTER_FQDN"
      export INSTALL_K3S_VERSION="${k8s_version}"
      export INSTALL_K3S_EXEC="server --secrets-encryption --disable traefik --node-ip $NODE_IP $TLS_SANS --write-kubeconfig-mode 0644"
      curl -sfL https://get.k3s.io | sh -

      status "stage-5:k8s-wait"
      timeout 300 bash -c 'until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done'

      status "stage-6:argo-bootstrap"
      # (Argo CD body added in a later task; no-op when no gitops repo is set.)

      status "stage-7:kubeconfig-publish"
      SERVER="$NODE_IP"; [ -n "$CLUSTER_FQDN" ] && SERVER="$CLUSTER_FQDN"
      sed "s|https://127.0.0.1:6443|https://$SERVER:6443|g" /etc/rancher/k3s/k3s.yaml >"$KUBECONFIG_OUT"
      chmod 0600 "$KUBECONFIG_OUT"

      status "complete"
      echo "[bootstrap] Bootstrap complete."

runcmd:
  - ["/usr/local/bin/kube-node-bootstrap.sh"]
