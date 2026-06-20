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
%{ if gitops_platform_repo_url != null ~}
  - path: /etc/kube-node/manifests/00-argocd-helmchart.yaml
    permissions: "0644"
    owner: root:root
    content: |
      apiVersion: v1
      kind: Namespace
      metadata:
        name: argocd
      ---
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: argocd
        namespace: kube-system
      spec:
        repo: https://argoproj.github.io/argo-helm
        chart: argo-cd
        targetNamespace: argocd
        createNamespace: false
        valuesContent: |-
          configs:
            params:
              server.insecure: "true"
  - path: /etc/kube-node/manifests/10-platform-app.yaml
    permissions: "0644"
    owner: root:root
    content: |
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: platform
        namespace: argocd
      spec:
        project: default
        source:
          repoURL: ${gitops_platform_repo_url}
          targetRevision: ${gitops_platform_revision}
          path: bootstrap
        destination:
          server: https://kubernetes.default.svc
          namespace: argocd
        syncPolicy:
          automated: { prune: true, selfHeal: true }
          syncOptions: ["CreateNamespace=true"]
%{ endif ~}
%{ if gitops_workloads_repo_url != null && gitops_platform_repo_url != null ~}
  - path: /etc/kube-node/manifests/20-workloads-app.yaml
    permissions: "0644"
    owner: root:root
    content: |
      apiVersion: argoproj.io/v1alpha1
      kind: Application
      metadata:
        name: workloads
        namespace: argocd
      spec:
        project: default
        source:
          repoURL: ${gitops_workloads_repo_url}
          targetRevision: ${gitops_workloads_revision}
          path: ${gitops_workloads_path}
        destination:
          server: https://kubernetes.default.svc
          namespace: argocd
        syncPolicy:
          automated: { prune: true, selfHeal: true }
          syncOptions: ["CreateNamespace=true"]
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
      %{ if gitops_platform_repo_url != null ~}
      KC=/etc/rancher/k3s/k3s.yaml
      kubectl --kubeconfig "$KC" apply -f /etc/kube-node/manifests/00-argocd-helmchart.yaml
      echo "[bootstrap] waiting for argocd-server to be ready..."
      timeout 600 bash -c 'until kubectl --kubeconfig '"$KC"' -n argocd rollout status deployment/argocd-server --timeout=30s 2>/dev/null; do sleep 15; done'
      kubectl --kubeconfig "$KC" apply -f /etc/kube-node/manifests/10-platform-app.yaml
      %{ if gitops_workloads_repo_url != null ~}
      kubectl --kubeconfig "$KC" apply -f /etc/kube-node/manifests/20-workloads-app.yaml
      %{ endif ~}
      %{ endif ~}

      status "stage-7:kubeconfig-publish"
      SERVER="$NODE_IP"; [ -n "$CLUSTER_FQDN" ] && SERVER="$CLUSTER_FQDN"
      sed "s|https://127.0.0.1:6443|https://$SERVER:6443|g" /etc/rancher/k3s/k3s.yaml >"$KUBECONFIG_OUT"
      chmod 0600 "$KUBECONFIG_OUT"

      status "complete"
      echo "[bootstrap] Bootstrap complete."

runcmd:
  - ["/usr/local/bin/kube-node-bootstrap.sh"]
