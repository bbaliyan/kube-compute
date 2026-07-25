#cloud-config
# RKE2 node bootstrap — AlmaLinux 10.
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
  # every boot (including stop-start cycles) before RKE2 and containerd start.
  # RKE2 + containerd + pods exhaust the kernel default of 128 inotify instances
  # within ~1 hour, leaving the control-plane session-worker unable to open a pty.
  # Separate filename from the stage-0 bridge/forwarding sysctls below (both live
  # under /etc/sysctl.d/, `sysctl --system` in stage-0 applies both).
  - path: /etc/sysctl.d/99-rke2-inotify.conf
    permissions: "0644"
    owner: root:root
    content: |
      fs.inotify.max_user_instances=1024
      fs.inotify.max_user_watches=524288

  # Bring hot-added vCPUs online. Ubuntu/RHEL-family guests on KVM-based hosts
  # (Proxmox) need this rule for CPU hotplug to be usable; inert (never fires) on
  # AWS/Azure, where instances don't get live vCPU hot-add. Hot-added memory needs
  # no rule: the kernel onlines it automatically (memory_hotplug.online_policy
  # defaults to auto-online).
  - path: /etc/udev/rules.d/80-hotplug-cpu-online.rules
    permissions: "0644"
    owner: root:root
    content: |
      SUBSYSTEM=="cpu", ACTION=="add", TEST=="online", ATTR{online}!="1", ATTR{online}="1"

%{ if trusted_ca_pem != null ~}
  - path: /etc/pki/ca-trust/source/anchors/trusted-ca.crt
    permissions: "0644"
    owner: root:root
    encoding: b64
    content: ${base64encode(trusted_ca_pem)}
%{ endif ~}
%{ if registry_mirror_url != null ~}
  - path: /etc/rancher/rke2/registries.yaml
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
%{ if node_role == "server-init" || node_role == "server-join" ~}
%{ for name, content in extra_server_manifests ~}
  - path: /var/lib/rancher/rke2/server/manifests/${name}
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

      # Renders a Helm chart to plain Kubernetes YAML on stdout using a helm
      # binary downloaded transiently for this one call and deleted
      # immediately after — no persistent footprint on the node (unlike
      # installing helm as an OS package, which this project deliberately
      # avoids). Never wraps output in RKE2's own HelmChart CRD: that CR's
      # finalizer runs `helm uninstall` on deletion with no supported way to
      # avoid it, which would fight (and later block handing off to) Argo
      # CD-native management. See
      # .scratch/cilium-argocd-gitops-handoff/map.md in the kube-claude repo.
      render_via_helm() {
        local release="$1" chart="$2" repo="$3" version="$4" namespace="$5" values_file="$6"
        local arch tmp
        arch="$(uname -m)"
        case "$arch" in
          x86_64) arch="amd64" ;;
          aarch64) arch="arm64" ;;
        esac
        tmp="$(mktemp -d)"
        curl -sfL "https://get.helm.sh/helm-v4.2.2-linux-$arch.tar.gz" | tar -xz -C "$tmp"
        "$tmp/linux-$arch/helm" template "$release" "$chart" --repo "$repo" --version "$version" --namespace "$namespace" --include-crds -f "$values_file"
        rm -rf "$tmp"
      }

      # RKE2 does not put its bundled kubectl on PATH by default (unlike K3s).
      export PATH="/var/lib/rancher/rke2/bin:$PATH"

      # Provider-neutral node IP discovery via the default-route source address.
      NODE_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
      [ -n "$NODE_IP" ] || { status "FAILED:no-node-ip"; exit 1; }

      # Apply inotify limits before anything else. systemd-sysctl.service runs during
      # sysinit.target — before cloud-init on first boot — so the sysctl.d file written
      # by write_files hasn't been read yet. Applying it here ensures the limits are in
      # place before RKE2 and containerd start. The sysctl.d file covers stop-start boots.
      sysctl -p /etc/sysctl.d/99-rke2-inotify.conf

      status "stage-0:os-prep"
      dnf makecache
      dnf install -y ca-certificates curl
      # kernel-modules-extra: AlmaLinux 10's minimal cloud image ships only
      # kernel-modules-core, which excludes nft_compat (the iptables-nft
      # legacy translation shim, CONFIG_NFT_COMPAT=m upstream but not part of
      # the minimal set — reasonable for a minimal image, since most modern
      # tooling talks to nft directly). Cilium's default VXLAN tunnel mode
      # still installs its tunnel-accept rule via classic iptables syntax
      # (`-p udp --dport 8472 ... -j ACCEPT`), which needs nft_compat to
      # translate. Without it, Cilium's iptables reconciliation fails
      # continuously and any pod needing fresh routing state (freshly
      # created/recreated) becomes unreachable via routed host/pod traffic —
      # confirmed on cluster-1. Installing it here keeps Cilium on its
      # portable tunnel-mode default (needed for multi-node topologies where
      # nodes aren't on a routable L2/L3, e.g. AWS across subnets/AZs) rather
      # than switching to native routing, which isn't a uniform fit across
      # this project's providers.
      #
      # Package name deliberately NOT pinned to "kernel-modules-extra-$(uname -r)":
      # AlmaLinux's BaseOS repo only retains the exact-NVR subpackage for the
      # latest kernel build, not the one baked into the base image, so an
      # exact-version request silently has nothing to match once a newer
      # point release supersedes it in the repo (confirmed on cluster-1 — the
      # base image's kernel was 211.7.3 but the repo only had 211.38.1's
      # packages, and the pinned install found nothing for the running
      # kernel). "kernel-modules-extra-matched" is the unversioned meta-package
      # dnf resolves correctly regardless of repo/running-kernel skew — it
      # pulls in the right versioned kernel-modules-extra as a dependency for
      # whichever kernel is actually running.
      dnf install -y kernel-modules-extra-matched
      modprobe nft_compat
      # br_netfilter and overlay are RHEL-family prerequisites for any CNI (every
      # RKE2/kubeadm RHEL install guide calls for this explicitly) — carried over
      # from the previous Ubuntu template rather than the previous AL2023 template,
      # which omitted this step for reasons that were never verified. Cheap and
      # idempotent even if the modules turn out to already be loaded/built-in.
      #
      # RHEL10-family kernels (6.12+, confirmed on AlmaLinux 10) dropped the
      # legacy br_netfilter module entirely — bridged traffic is filtered
      # natively via nftables' bridge-family hooks (nf_conntrack_bridge et al,
      # auto-loaded with the bridge module), so there's no module to load and
      # no bridge-nf-call-iptables/-ip6tables knob to set on those kernels.
      # RHEL9-family kernels still ship br_netfilter and need both.
      if modinfo br_netfilter >/dev/null 2>&1; then
        printf 'br_netfilter\noverlay\n' >/etc/modules-load.d/rke2.conf
        modprobe br_netfilter
      else
        printf 'overlay\n' >/etc/modules-load.d/rke2.conf
      fi
      modprobe overlay
      printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/98-rke2-bridge.conf
      if [ -d /proc/sys/net/bridge ]; then
        printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\n' >>/etc/sysctl.d/98-rke2-bridge.conf
      fi
      sysctl --system

      status "stage-1:os-trust"
      %{ if trusted_ca_pem != null ~}
      update-ca-trust extract
      %{ endif ~}

      status "stage-2:registry-mirror"
      %{ if registry_mirror_url != null ~}
      # Preflight: verify the mirror is reachable before RKE2 tries to pull through it.
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

      if [ ! -f /etc/yum.repos.d/rancher-rke2-common.repo ]; then
        {
          echo '[rancher-rke2-common-stable]'
          echo 'name=Rancher RKE2 Common (stable)'
          echo 'baseurl=https://rpm.rancher.io/rke2/stable/common/centos/10/noarch'
          echo 'enabled=1'
          echo 'gpgcheck=1'
          echo 'gpgkey=https://rpm.rancher.io/public.key'
        } >/etc/yum.repos.d/rancher-rke2-common.repo
      fi
      dnf makecache

      for attempt in 1 2 3; do
        rpm --import https://rpm.rancher.io/public.key && break
        [[ $attempt -eq 3 ]] && { status "FAILED:rancher-gpg-import"; exit 1; }
        echo "[bootstrap] GPG import attempt $attempt failed, retrying in 10s..."
        sleep 10
      done

      for attempt in 1 2 3 4 5; do
        dnf install -y rke2-selinux && break
        if [[ $attempt -eq 5 ]]; then
          status "FAILED:rke2-selinux-preinstall"
          exit 1
        fi
        echo "[bootstrap] rke2-selinux preinstall attempt $attempt failed, retrying in 15s..."
        sleep 15
        pkill -x dnf 2>/dev/null || true
        pkill -x rpm 2>/dev/null || true
      done

      status "stage-4:k8s-install"
      # RKE2 has no K3s-style single exec-string env var (INSTALL_K3S_EXEC) — some
      # flags (RKE2_TOKEN, RKE2_URL, RKE2_KUBECONFIG_MODE) have per-flag env vars, but
      # tls-san and node-taint (repeatable list flags this template needs) do not, so
      # config is written to /etc/rancher/rke2/config.yaml instead, per RKE2's own
      # documented approach.
      mkdir -p /etc/rancher/rke2
      %{ if node_role == "server-init" ~}
      SERVER_LINE=""
      %{ if registration_address != null ~}
      # Runtime init-vs-join probe: a replaced first server must rejoin an already-healthy
      # cluster rather than blindly re-initializing etcd, which would split-brain a live
      # quorum. Genesis boot finds the registration endpoint unreachable and initializes.
      # RKE2 has no --cluster-init flag at all: the first server is simply the one whose
      # config.yaml has no "server:" key; a rejoining replacement gets one, same as
      # server-join below.
      PROBE_CODE="$(curl -sk --max-time 5 -o /dev/null -w '%%{http_code}' "https://${registration_address}:6443/readyz" 2>/dev/null || true)"
      if [ -n "$PROBE_CODE" ] && [ "$PROBE_CODE" != "000" ]; then
        status "stage-4:k8s-install:rejoin-detected"
        SERVER_LINE="server: https://${registration_address}:9345"
      fi
      %{ endif ~}
      cat >/etc/rancher/rke2/config.yaml <<EOF
      $SERVER_LINE
      token: ${cluster_token == null ? "" : cluster_token}
      agent-token: ${cluster_agent_token == null ? "" : cluster_agent_token}
      node-ip: $NODE_IP
      tls-san:
        - $NODE_IP
      %{~ if cluster_fqdn != null ~}
        - ${cluster_fqdn}
      %{~ endif ~}
      %{~ for san in extra_tls_sans ~}
        - ${san}
      %{~ endfor ~}
      write-kubeconfig-mode: "0644"
      secrets-encryption: true
      disable-cloud-controller: true
      # Disables whatever RKE2's default ingress controller is for the installed
      # version (ingress-nginx or Traefik, depending on release — see
      # docs.rke2.io/networking/networking_services). This project doesn't bundle
      # an ingress controller at bootstrap, mirroring the K3s template's
      # --disable traefik.
      ingress-controller: none
      %{~ if control_plane_taint ~}
      node-taint:
        - "CriticalAddonsOnly=true:NoExecute"
      %{~ endif ~}
      %{~ if cni == "cilium" ~}
      cni: cilium
      disable-kube-proxy: true
      # Without this, RKE2 installs its own bundled rke2-cilium addon (a
      # separate HelmChart CR) alongside the genesis-rendered Cilium manifest
      # below — both fighting over the same cilium-operator/cilium objects in
      # kube-system. Confirmed via a real cluster-1 apply; see
      # .scratch/cilium-argocd-gitops-handoff/map.md in the kube-claude repo.
      disable:
        - rke2-cilium
      %{~ endif ~}
      %{~ if etcd_snapshot_enabled ~}
      etcd-snapshot-schedule-cron: '${etcd_snapshot_schedule_cron}'
      etcd-snapshot-retention: ${etcd_snapshot_retention}
      %{~ if etcd_snapshot_object_store_bucket != null ~}
      etcd-s3: true
      etcd-s3-bucket: ${etcd_snapshot_object_store_bucket}
      %{~ if etcd_snapshot_object_store_region != null ~}
      etcd-s3-region: ${etcd_snapshot_object_store_region}
      %{~ endif ~}
      %{~ if etcd_snapshot_object_store_endpoint != null ~}
      etcd-s3-endpoint: ${etcd_snapshot_object_store_endpoint}
      %{~ endif ~}
      %{~ if etcd_snapshot_object_store_folder != null ~}
      etcd-s3-folder: ${etcd_snapshot_object_store_folder}
      %{~ endif ~}
      %{~ endif ~}
      %{~ endif ~}
      EOF
      %{ if cni == "cilium" ~}
      # Genesis-only (this project's server-join nodes never re-render this —
      # Cilium is a cluster-wide DaemonSet/Deployment, not per-node state).
      # Rendered via a transient helm binary (render_via_helm, defined above)
      # rather than RKE2's own HelmChart CRD — see the comment on that
      # function for why.
      mkdir -p /var/lib/rancher/rke2/server/manifests
      CILIUM_VALUES="$(mktemp)"
      echo "${cilium_values_b64}" | base64 -d >"$CILIUM_VALUES"
      render_via_helm cilium cilium https://helm.cilium.io/ "${cilium_version}" kube-system "$CILIUM_VALUES" >/var/lib/rancher/rke2/server/manifests/cilium.yaml
      rm -f "$CILIUM_VALUES"
      %{ endif ~}
      export INSTALL_RKE2_VERSION="${k8s_version}"
      curl -sfL https://get.rke2.io | sh -
      systemctl enable rke2-server.service
      systemctl start rke2-server.service
      %{ endif ~}
      %{ if node_role == "server-join" ~}
      cat >/etc/rancher/rke2/config.yaml <<EOF
      server: https://${registration_address}:9345
      token: ${cluster_token == null ? "" : cluster_token}
      agent-token: ${cluster_agent_token == null ? "" : cluster_agent_token}
      node-ip: $NODE_IP
      tls-san:
        - $NODE_IP
      %{~ if cluster_fqdn != null ~}
        - ${cluster_fqdn}
      %{~ endif ~}
      %{~ for san in extra_tls_sans ~}
        - ${san}
      %{~ endfor ~}
      write-kubeconfig-mode: "0644"
      secrets-encryption: true
      disable-cloud-controller: true
      # Disables whatever RKE2's default ingress controller is for the installed
      # version (ingress-nginx or Traefik, depending on release — see
      # docs.rke2.io/networking/networking_services). This project doesn't bundle
      # an ingress controller at bootstrap, mirroring the K3s template's
      # --disable traefik.
      ingress-controller: none
      %{~ if control_plane_taint ~}
      node-taint:
        - "CriticalAddonsOnly=true:NoExecute"
      %{~ endif ~}
      %{~ if cni == "cilium" ~}
      cni: cilium
      disable-kube-proxy: true
      # Every server needs this, not just the one rendering the manifest
      # (Ticket 04 of .scratch/cilium-argocd-gitops-handoff/map.md): it stops
      # *this node's own* RKE2 supervisor from installing its bundled
      # rke2-cilium addon, independent of who wrote the actual manifest.
      disable:
        - rke2-cilium
      %{~ endif ~}
      %{~ if etcd_snapshot_enabled ~}
      etcd-snapshot-schedule-cron: '${etcd_snapshot_schedule_cron}'
      etcd-snapshot-retention: ${etcd_snapshot_retention}
      %{~ if etcd_snapshot_object_store_bucket != null ~}
      etcd-s3: true
      etcd-s3-bucket: ${etcd_snapshot_object_store_bucket}
      %{~ if etcd_snapshot_object_store_region != null ~}
      etcd-s3-region: ${etcd_snapshot_object_store_region}
      %{~ endif ~}
      %{~ if etcd_snapshot_object_store_endpoint != null ~}
      etcd-s3-endpoint: ${etcd_snapshot_object_store_endpoint}
      %{~ endif ~}
      %{~ if etcd_snapshot_object_store_folder != null ~}
      etcd-s3-folder: ${etcd_snapshot_object_store_folder}
      %{~ endif ~}
      %{~ endif ~}
      %{~ endif ~}
      EOF
      export INSTALL_RKE2_VERSION="${k8s_version}"
      curl -sfL https://get.rke2.io | sh -

      # Additional control-plane nodes join RKE2's embedded-etcd cluster one at a time:
      # this is an upstream etcd limitation (only one non-voting "learner" member allowed
      # in the cluster at a time — https://etcd.io/docs/v3.4/learning/design-learner/),
      # not a K3s-only quirk, and RKE2 hits the same class of failure (see
      # rancher/rke2#3562, #4035, #349: "cred/passwd newer than datastore"). This block
      # staggers by this node's own index (parsed from its hostname suffix — only needs
      # to be distinct per sibling within one provider; the numeric base need not match
      # across providers), and self-heals by wiping local server state — TLS,
      # credentials, and any partially-written etcd data — and retrying if a collision
      # still slips through.
      NODE_INDEX="$(hostname | grep -oE '[0-9]+$' || echo 0)"
      sleep $((NODE_INDEX * 60))

      systemctl enable rke2-server.service
      JOIN_ATTEMPT=0
      until systemctl start rke2-server.service && timeout 90 bash -c 'until kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done'; do
        JOIN_ATTEMPT=$((JOIN_ATTEMPT + 1))
        [ "$JOIN_ATTEMPT" -ge 3 ] && { status "FAILED:k8s-install-join-race"; exit 1; }
        status "stage-4:k8s-install:retry-$JOIN_ATTEMPT"
        systemctl stop rke2-server 2>/dev/null || true
        rm -rf /var/lib/rancher/rke2/server/tls /var/lib/rancher/rke2/server/cred /var/lib/rancher/rke2/server/db
        sleep 15
      done
      %{ endif ~}
      %{ if node_role == "worker" ~}
      AGENT_TOKEN="$(${agent_token_fetch_command})"
      [ -n "$AGENT_TOKEN" ] || { status "FAILED:agent-token-fetch"; exit 1; }
      cat >/etc/rancher/rke2/config.yaml <<EOF
      server: https://${registration_address}:9345
      token: $AGENT_TOKEN
      node-ip: $NODE_IP
      %{~ if length(node_labels) > 0 ~}
      node-label:
      %{~ for label_key, label_val in node_labels ~}
        - "${label_key}=${label_val}"
      %{~ endfor ~}
      %{~ endif ~}
      EOF
      export INSTALL_RKE2_TYPE="agent"
      export INSTALL_RKE2_VERSION="${k8s_version}"
      curl -sfL https://get.rke2.io | sh -
      systemctl enable rke2-agent.service
      systemctl start rke2-agent.service
      %{ endif ~}
      %{ if node_role != "server-init" && node_role != "server-join" && node_role != "worker" ~}
      echo "[bootstrap] node_role=${node_role} is not implemented by this build of node-bootstrap" >&2
      status "FAILED:node-role-unimplemented"
      exit 1
      %{ endif ~}

      status "stage-5:k8s-wait"
      %{ if node_role == "worker" ~}
      timeout 300 bash -c 'until systemctl is-active --quiet rke2-agent; do sleep 5; done' || { status "FAILED:k8s-wait"; exit 1; }
      %{ else ~}
      timeout 300 bash -c 'until kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done' || { status "FAILED:k8s-wait"; exit 1; }
      %{ endif ~}

      status "stage-6:argo-bootstrap"
      %{ if gitops_platform_repo_url != null && node_role == "server-init" ~}
      KC=/etc/rancher/rke2/rke2.yaml
      # Genesis only needs *a* working pinned Argo CD version, not the
      # consumer's target version — kube-platform's own self-managing
      # Application is what carries the consumer's chosen version going
      # forward (an ordinary in-place Helm upgrade, not a risky swap). See
      # .scratch/cilium-argocd-gitops-handoff/map.md in the kube-claude repo.
      ARGOCD_VALUES="$(mktemp)"
      echo "${argocd_values_b64}" | base64 -d >"$ARGOCD_VALUES"
      {
        echo "apiVersion: v1"
        echo "kind: Namespace"
        echo "metadata:"
        echo "  name: argocd"
        echo "---"
        render_via_helm argocd argo-cd https://argoproj.github.io/argo-helm "${argocd_version}" argocd "$ARGOCD_VALUES"
      # --server-side is required, not stylistic: a plain (client-side) apply
      # stores the whole previous config in a last-applied-configuration
      # annotation for 3-way merging, and Argo CD's own
      # applicationsets.argoproj.io CRD is large enough to exceed
      # Kubernetes' 262144-byte annotation-size limit — confirmed via a real
      # cluster-1 apply against node-bootstrap's equivalent step
      # ("metadata.annotations: Too long"). Server-side apply uses
      # field-manager metadata instead of that annotation, sidestepping the
      # limit entirely.
      } | kubectl --kubeconfig "$KC" apply --server-side -f -
      rm -f "$ARGOCD_VALUES"
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
      sed "s|https://127.0.0.1:6443|https://$SERVER:6443|g" /etc/rancher/rke2/rke2.yaml >"$KUBECONFIG_OUT"
      chmod 0640 "$KUBECONFIG_OUT"
      chown root:almalinux "$KUBECONFIG_OUT"
      %{ endif ~}

      status "complete"
      echo "[bootstrap] Bootstrap complete."

runcmd:
  - ["/usr/local/bin/kube-compute-bootstrap.sh"]
