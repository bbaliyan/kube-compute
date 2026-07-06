#cloud-config
# K3s node bootstrap — Amazon Linux 2023.
# Status is written to a local file and read out-of-band by the control-plane
# verb-scripts (no inbound port). Stage sequence is fixed; optional stages emit
# their status line even when their body is skipped.
hostname: ${cluster_name}
write_files:
  - path: /etc/kube-node/env
    permissions: "0640"
    owner: root:root
    content: |
      CLUSTER_NAME="${cluster_name}"
      K8S_VERSION="${k8s_version}"
      CLUSTER_FQDN="${cluster_fqdn == null ? "" : cluster_fqdn}"

  # inotify limits — written here so systemd-sysctl.service applies them on
  # every boot (including stop-start cycles) before K3s and containerd start.
  # K3s + containerd + pods exhaust the kernel default of 128 inotify instances
  # within ~1 hour, leaving the SSM session-worker unable to open a pty.
  - path: /etc/sysctl.d/99-k3s.conf
    permissions: "0644"
    owner: root:root
    content: |
      fs.inotify.max_user_instances=1024
      fs.inotify.max_user_watches=524288

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
%{ if trusted_ca_pem != null ~}
      configs:
        # Pin containerd's TLS verification of the mirror host to the trusted CA.
        # Belt-and-suspenders alongside the OS trust store: containerd verifies a
        # privately-signed mirror cert via this CA regardless of system-bundle quirks.
        "${trimprefix(trimprefix(registry_mirror_url, "https://"), "http://")}":
          tls:
            ca_file: /etc/pki/ca-trust/source/anchors/trusted-ca.crt
%{ endif ~}
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
              # Deliberate: TLS terminates upstream (ingress / load balancer); Argo CD serves plain HTTP behind it.
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
          helm:
            parameters:
              - name: platformRepoURL
                value: "${gitops_platform_repo_url}"
              - name: platformRevision
                value: "${gitops_platform_revision}"
              - name: certMode
                value: "${cert_mode}"
              - name: clusterName
                value: "${cluster_name}"
              - name: clusterFqdnSuffix
                value: "${cluster_fqdn == null ? "" : cluster_fqdn}"
              - name: trustedCaPemB64
                value: "${trusted_ca_pem == null ? "" : base64encode(trusted_ca_pem)}"
              - name: workloadsRepoURL
                value: "${gitops_workloads_repo_url == null ? "" : gitops_workloads_repo_url}"
              - name: workloadsRevision
                value: "${gitops_workloads_revision}"
              - name: workloadsPath
                value: "${gitops_workloads_path}"
%{ for name, val in platform_extra_helm_parameters ~}
              - name: ${name}
                value: "${val}"
%{ endfor ~}
            valuesObject: ${jsonencode(merge(coalesce(platform_helm_values_object, {}), { extraTags = extra_tags }))}
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

      # Apply inotify limits before anything else. systemd-sysctl.service runs during
      # sysinit.target — before cloud-init on first boot — so the sysctl.d file written
      # by write_files hasn't been read yet. Applying it here ensures the limits are in
      # place before K3s and containerd start. The sysctl.d file covers stop-start boots.
      sysctl -p /etc/sysctl.d/99-k3s.conf

      status "stage-1:os-trust"
      %{ if trusted_ca_pem != null ~}
      update-ca-trust extract
      %{ endif ~}

      status "stage-2:registry-mirror"
      %{ if registry_mirror_url != null ~}
      # Preflight: verify the mirror is reachable before K3s tries to pull through it.
      # A 401 is acceptable — it means the registry is up and enforcing auth. We only
      # fail on connection errors (000) or unexpected codes, which would otherwise surface
      # later as cryptic image-pull failures. The trusted CA installed in stage-1 lets curl
      # verify a privately-signed mirror cert.
      MIRROR_CODE="$(curl --silent --output /dev/null --write-out '%%{http_code}' --max-time 10 "${registry_mirror_url}/v2/" || true)"
      if [ "$MIRROR_CODE" != "200" ] && [ "$MIRROR_CODE" != "401" ]; then
        status "FAILED:registry-mirror-unreachable"
        echo "[bootstrap] registry mirror ${registry_mirror_url} unreachable (HTTP $MIRROR_CODE)" >&2
        exit 1
      fi
      echo "[bootstrap] registry mirror ${registry_mirror_url} reachable (HTTP $MIRROR_CODE)"
      %{ else ~}
      # No registry mirror configured — containerd pulls from upstream registries directly.
      %{ endif ~}

      status "stage-3:selinux-prep"
      # Quiesce packagekit before any RPM operations — it holds /var/lib/rpm/.rpm.lock
      # intermittently and causes dnf to fail mid-transaction.
      systemctl stop packagekit 2>/dev/null || true
      systemctl stop packagekit.socket 2>/dev/null || true

      if [ ! -f /etc/yum.repos.d/rancher-k3s-common.repo ]; then
        {
          echo '[rancher-k3s-common-stable]'
          echo 'name=Rancher K3s Common (stable)'
          echo 'baseurl=https://rpm.rancher.io/k3s/stable/common/centos/9/noarch'
          echo 'enabled=1'
          echo 'gpgcheck=1'
          echo 'gpgkey=https://rpm.rancher.io/public.key'
        } >/etc/yum.repos.d/rancher-k3s-common.repo
      fi
      dnf makecache

      for attempt in 1 2 3; do
        rpm --import https://rpm.rancher.io/public.key && break
        [[ $attempt -eq 3 ]] && { status "FAILED:rancher-gpg-import"; exit 1; }
        echo "[bootstrap] GPG import attempt $attempt failed, retrying in 10s..."
        sleep 10
      done

      for attempt in 1 2 3 4 5; do
        dnf install -y k3s-selinux && break
        if [[ $attempt -eq 5 ]]; then
          status "FAILED:k3s-selinux-preinstall"
          exit 1
        fi
        echo "[bootstrap] k3s-selinux preinstall attempt $attempt failed, retrying in 15s..."
        sleep 15
        pkill -x dnf 2>/dev/null || true
        pkill -x rpm 2>/dev/null || true
      done

      status "stage-4:k8s-install"
      %{ if node_role == "server-init" ~}
      TLS_SANS="--tls-san $NODE_IP"
      [ -n "$CLUSTER_FQDN" ] && TLS_SANS="$TLS_SANS --tls-san $CLUSTER_FQDN"
      export INSTALL_K3S_VERSION="${k8s_version}"
      export INSTALL_K3S_EXEC="server --cluster-init --secrets-encryption --disable traefik --disable-cloud-controller --node-ip $NODE_IP $TLS_SANS --write-kubeconfig-mode 0644${control_plane_taint ? " --node-taint CriticalAddonsOnly=true:NoExecute" : ""}"
      curl -sfL https://get.k3s.io | sh -
      %{ endif ~}
      %{ if node_role == "worker" ~}
      AGENT_TOKEN="$(${agent_token_fetch_command})"
      [ -n "$AGENT_TOKEN" ] || { status "FAILED:agent-token-fetch"; exit 1; }
      NODE_LABEL_FLAGS=""
      %{ for label_key, label_val in node_labels ~}
      NODE_LABEL_FLAGS="$NODE_LABEL_FLAGS --node-label ${label_key}=${label_val}"
      %{ endfor ~}
      export INSTALL_K3S_VERSION="${k8s_version}"
      export INSTALL_K3S_EXEC="agent --server https://${registration_address}:6443 --node-ip $NODE_IP$NODE_LABEL_FLAGS"
      INSTALL_K3S_TOKEN="$AGENT_TOKEN" curl -sfL https://get.k3s.io | sh -
      %{ endif ~}
      %{ if node_role != "server-init" && node_role != "worker" ~}
      echo "[bootstrap] node_role=${node_role} is not implemented by this build of node-bootstrap" >&2
      status "FAILED:node-role-unimplemented"
      exit 1
      %{ endif ~}

      status "stage-5:k8s-wait"
      %{ if node_role == "worker" ~}
      timeout 300 bash -c 'until systemctl is-active --quiet k3s-agent; do sleep 5; done'
      %{ else ~}
      timeout 300 bash -c 'until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done'
      %{ endif ~}

      status "stage-6:argo-bootstrap"
      %{ if gitops_platform_repo_url != null ~}
      KC=/etc/rancher/k3s/k3s.yaml
      kubectl --kubeconfig "$KC" apply -f /etc/kube-node/manifests/00-argocd-helmchart.yaml
      echo "[bootstrap] waiting for argocd-server to be ready..."
      timeout 600 bash -c 'until kubectl --kubeconfig '"$KC"' -n argocd rollout status deployment/argocd-server --timeout=30s 2>/dev/null; do sleep 15; done'
      kubectl --kubeconfig "$KC" apply -f /etc/kube-node/manifests/10-platform-app.yaml
      %{ endif ~}

      status "stage-7:kubeconfig-publish"
      %{ if node_role == "worker" ~}
      echo "[bootstrap] node_role=worker has no local kubeconfig to publish."
      %{ else ~}
      SERVER="$NODE_IP"; [ -n "$CLUSTER_FQDN" ] && SERVER="$CLUSTER_FQDN"
      sed "s|https://127.0.0.1:6443|https://$SERVER:6443|g" /etc/rancher/k3s/k3s.yaml >"$KUBECONFIG_OUT"
      chmod 0600 "$KUBECONFIG_OUT"
      %{ endif ~}

      status "complete"
      echo "[bootstrap] Bootstrap complete."

runcmd:
  - ["/usr/local/bin/kube-node-bootstrap.sh"]
