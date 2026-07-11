#cloud-config
# K3s node bootstrap — Amazon Linux 2023.
# Status is written to a local file and read out-of-band by the control-plane
# verb-scripts (no inbound port). Stage sequence is fixed; optional stages emit
# their status line even when their body is skipped.
%{ if node_name != null ~}
hostname: ${node_name}
%{ endif ~}
write_files:
  - path: /etc/kube-compute/env
    permissions: "0640"
    owner: root:root
    content: |
      CLUSTER_NAME="${cluster_name}"
      K8S_VERSION="${k8s_version}"
      CLUSTER_FQDN="${cluster_fqdn == null ? "" : cluster_fqdn}"
      REGISTRATION_ADDRESS="${registration_address == null ? "" : registration_address}"

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
%{ if gitops_platform_repo_url != null && node_role == "server-init" ~}
  - path: /etc/kube-compute/manifests/00-argocd-helmchart.yaml
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
        version: "${argocd_version}"
        targetNamespace: argocd
        createNamespace: false
        valuesContent: |-
          configs:
            params:
              # Deliberate: TLS terminates upstream (ingress / load balancer); Argo CD serves plain HTTP behind it.
              server.insecure: "true"
  - path: /etc/kube-compute/manifests/10-platform-app.yaml
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
%{ if cni == "cilium" && (node_role == "server-init" || node_role == "server-join") ~}
  - path: /var/lib/rancher/k3s/server/manifests/cilium.yaml
    permissions: "0600"
    owner: root:root
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: cilium
        namespace: kube-system
      spec:
        repo: https://helm.cilium.io/
        chart: cilium
        version: "${cilium_version}"
        targetNamespace: kube-system
        bootstrap: true
        valuesContent: |-
          kubeProxyReplacement: true
          k8sServiceHost: "127.0.0.1"
          k8sServicePort: 6444
          # cilium-operator registers the CRDs cilium-agent waits on before it can
          # start. cilium-agent's chart-default toleration is a genuine blanket
          # one (key-less "Exists", matches every taint) — cilium-operator's
          # defaults to empty. During bootstrap the node can carry more than one
          # blocking taint at once: this project's own CriticalAddonsOnly (see
          # control_plane_taint above) AND Kubernetes' own automatic
          # node.kubernetes.io/not-ready, since the node can't report Ready until
          # Cilium is actually running — a chicken-and-egg trap if the operator
          # only tolerates one of them. Match cilium-agent's own blanket
          # toleration exactly rather than enumerating individual taints one
          # discovery at a time.
          operator:
            tolerations:
              - operator: Exists
          ipam:
            operator:
              clusterPoolIPv4PodCIDRList: ["10.42.0.0/16"]
%{ endif ~}
%{ if node_role == "server-init" || node_role == "server-join" ~}
%{ for name, content in extra_server_manifests ~}
  - path: /var/lib/rancher/k3s/server/manifests/${name}
    permissions: "0600"
    owner: root:root
    content: |
      ${indent(6, content)}
%{ endfor ~}
%{ endif ~}
  - path: /usr/local/bin/kube-compute-bootstrap.sh
    permissions: "0755"
    owner: root:root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      source /etc/kube-compute/env

      STATUS_FILE=/var/log/kube-compute/bootstrap-status
      KUBECONFIG_OUT=/var/lib/kube-compute/kubeconfig
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
      %{ for san in extra_tls_sans ~}
      TLS_SANS="$TLS_SANS --tls-san ${san}"
      %{ endfor ~}
      export INSTALL_K3S_VERSION="${k8s_version}"
      export K3S_TOKEN="${cluster_token == null ? "" : cluster_token}"
      SNAPSHOT_ARGS=""
      %{ if etcd_snapshot_enabled ~}
      SNAPSHOT_ARGS="--etcd-snapshot-schedule-cron '${etcd_snapshot_schedule_cron}' --etcd-snapshot-retention ${etcd_snapshot_retention}"
      %{ if etcd_snapshot_object_store_bucket != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3 --etcd-s3-bucket ${etcd_snapshot_object_store_bucket}"
      %{ if etcd_snapshot_object_store_region != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3-region ${etcd_snapshot_object_store_region}"
      %{ endif ~}
      %{ if etcd_snapshot_object_store_endpoint != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3-endpoint ${etcd_snapshot_object_store_endpoint}"
      %{ endif ~}
      %{ if etcd_snapshot_object_store_folder != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3-folder ${etcd_snapshot_object_store_folder}"
      %{ endif ~}
      %{ endif ~}
      %{ endif ~}
      CNI_ARGS="${cni == "cilium" ? "--flannel-backend=none --disable-network-policy --disable-kube-proxy" : ""}"
      SERVER_ARGS="--secrets-encryption --disable traefik --disable-cloud-controller --agent-token ${cluster_agent_token == null ? "" : cluster_agent_token} --node-ip $NODE_IP $TLS_SANS --write-kubeconfig-mode 0644${control_plane_taint ? " --node-taint CriticalAddonsOnly=true:NoExecute" : ""} $SNAPSHOT_ARGS $CNI_ARGS"
      %{ if registration_address != null ~}
      # Runtime init-vs-join probe: a replaced first server must rejoin an already-healthy
      # cluster rather than blindly re-initializing etcd, which would split-brain a live
      # quorum. Genesis boot finds the registration endpoint unreachable and initializes.
      PROBE_CODE="$(curl -sk --max-time 5 -o /dev/null -w '%%{http_code}' "https://${registration_address}:6443/readyz" 2>/dev/null || true)"
      if [ -n "$PROBE_CODE" ] && [ "$PROBE_CODE" != "000" ]; then
        status "stage-4:k8s-install:rejoin-detected"
        export INSTALL_K3S_EXEC="server --server https://${registration_address}:6443 $SERVER_ARGS"
      else
        export INSTALL_K3S_EXEC="server --cluster-init $SERVER_ARGS"
      fi
      %{ else ~}
      export INSTALL_K3S_EXEC="server --cluster-init $SERVER_ARGS"
      %{ endif ~}
      curl -sfL https://get.k3s.io | sh -
      %{ endif ~}
      %{ if node_role == "server-join" ~}
      TLS_SANS="--tls-san $NODE_IP"
      [ -n "$CLUSTER_FQDN" ] && TLS_SANS="$TLS_SANS --tls-san $CLUSTER_FQDN"
      %{ for san in extra_tls_sans ~}
      TLS_SANS="$TLS_SANS --tls-san ${san}"
      %{ endfor ~}
      export INSTALL_K3S_VERSION="${k8s_version}"
      export K3S_TOKEN="${cluster_token == null ? "" : cluster_token}"
      SNAPSHOT_ARGS=""
      %{ if etcd_snapshot_enabled ~}
      SNAPSHOT_ARGS="--etcd-snapshot-schedule-cron '${etcd_snapshot_schedule_cron}' --etcd-snapshot-retention ${etcd_snapshot_retention}"
      %{ if etcd_snapshot_object_store_bucket != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3 --etcd-s3-bucket ${etcd_snapshot_object_store_bucket}"
      %{ if etcd_snapshot_object_store_region != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3-region ${etcd_snapshot_object_store_region}"
      %{ endif ~}
      %{ if etcd_snapshot_object_store_endpoint != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3-endpoint ${etcd_snapshot_object_store_endpoint}"
      %{ endif ~}
      %{ if etcd_snapshot_object_store_folder != null ~}
      SNAPSHOT_ARGS="$SNAPSHOT_ARGS --etcd-s3-folder ${etcd_snapshot_object_store_folder}"
      %{ endif ~}
      %{ endif ~}
      %{ endif ~}
      CNI_ARGS="${cni == "cilium" ? "--flannel-backend=none --disable-network-policy --disable-kube-proxy" : ""}"
      SERVER_ARGS="--secrets-encryption --disable traefik --disable-cloud-controller --node-ip $NODE_IP $TLS_SANS --write-kubeconfig-mode 0644${control_plane_taint ? " --node-taint CriticalAddonsOnly=true:NoExecute" : ""} $SNAPSHOT_ARGS $CNI_ARGS"
      export INSTALL_K3S_EXEC="server --server https://${registration_address}:6443 $SERVER_ARGS"

      # Additional control-plane nodes join K3s' embedded-etcd cluster one at a time by
      # design (K3s HA docs: concurrent server joins are unsupported). The original design
      # assumed server-join's retry-against-registration-endpoint behavior made ordering
      # between siblings unnecessary (see aws-control-plane's control_plane_additional comment) —
      # in practice, two siblings booting close together still race K3s' bootstrap-data
      # reconciliation and the loser fails permanently ("cred/passwd newer than
      # datastore"). This does NOT self-heal via systemd's restart-on-failure, since the
      # stale local bootstrap files persist across every restart. This block supersedes
      # that assumption: it staggers by this node's own index (parsed from its hostname
      # suffix — only needs to be distinct per sibling within one provider; the numeric
      # base need not match across providers), and self-heals by wiping local server
      # state — TLS, credentials, and any partially-written etcd data — and retrying if a
      # collision still slips through.
      NODE_INDEX="$(hostname | grep -oE '[0-9]+$' || echo 0)"
      sleep $((NODE_INDEX * 60))

      JOIN_ATTEMPT=0
      until curl -sfL https://get.k3s.io | sh - && timeout 90 bash -c 'until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done'; do
        JOIN_ATTEMPT=$((JOIN_ATTEMPT + 1))
        [ "$JOIN_ATTEMPT" -ge 3 ] && { status "FAILED:k8s-install-join-race"; exit 1; }
        status "stage-4:k8s-install:retry-$JOIN_ATTEMPT"
        systemctl stop k3s 2>/dev/null || true
        rm -rf /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/cred /var/lib/rancher/k3s/server/db
        sleep 15
      done
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
      export K3S_TOKEN="$AGENT_TOKEN"
      curl -sfL https://get.k3s.io | sh -
      %{ endif ~}
      %{ if node_role != "server-init" && node_role != "server-join" && node_role != "worker" ~}
      echo "[bootstrap] node_role=${node_role} is not implemented by this build of node-bootstrap" >&2
      status "FAILED:node-role-unimplemented"
      exit 1
      %{ endif ~}

      status "stage-5:k8s-wait"
      %{ if node_role == "worker" ~}
      timeout 300 bash -c 'until systemctl is-active --quiet k3s-agent; do sleep 5; done' || { status "FAILED:k8s-wait"; exit 1; }
      %{ else ~}
      timeout 300 bash -c 'until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done' || { status "FAILED:k8s-wait"; exit 1; }
      %{ endif ~}

      status "stage-6:argo-bootstrap"
      %{ if gitops_platform_repo_url != null && node_role == "server-init" ~}
      KC=/etc/rancher/k3s/k3s.yaml
      kubectl --kubeconfig "$KC" apply -f /etc/kube-compute/manifests/00-argocd-helmchart.yaml
      echo "[bootstrap] waiting for argocd-server to be ready..."
      timeout 600 bash -c 'until kubectl --kubeconfig '"$KC"' -n argocd rollout status deployment/argocd-server --timeout=30s 2>/dev/null; do sleep 15; done' || { status "FAILED:argo-bootstrap"; exit 1; }
      kubectl --kubeconfig "$KC" apply -f /etc/kube-compute/manifests/10-platform-app.yaml
      %{ endif ~}

      status "stage-7:kubeconfig-publish"
      %{ if node_role == "worker" ~}
      echo "[bootstrap] node_role=worker has no local kubeconfig to publish."
      %{ else ~}
      SERVER="$NODE_IP"
      [ -n "$CLUSTER_FQDN" ] && SERVER="$CLUSTER_FQDN"
      [ -n "$REGISTRATION_ADDRESS" ] && SERVER="$REGISTRATION_ADDRESS"
      sed "s|https://127.0.0.1:6443|https://$SERVER:6443|g" /etc/rancher/k3s/k3s.yaml >"$KUBECONFIG_OUT"
      chmod 0600 "$KUBECONFIG_OUT"
      %{ endif ~}

      status "complete"
      echo "[bootstrap] Bootstrap complete."

runcmd:
  - ["/usr/local/bin/kube-compute-bootstrap.sh"]
