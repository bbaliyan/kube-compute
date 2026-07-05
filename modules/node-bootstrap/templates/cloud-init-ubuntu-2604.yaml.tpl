#cloud-config
# K3s node bootstrap — Ubuntu 26.04 LTS.
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

  # Bring hot-added vCPUs online. Ubuntu's stock 40-vm-hotadd.rules is gated to
  # Hyper-V/Xen guests, so KVM-based hosts need this rule for CPU hotplug to be
  # usable. Hot-added memory needs no rule: the kernel onlines it automatically
  # (memory_hotplug.online_policy defaults to auto-online on Ubuntu).
  - path: /etc/udev/rules.d/80-hotplug-cpu-online.rules
    permissions: "0644"
    owner: root:root
    content: |
      SUBSYSTEM=="cpu", ACTION=="add", TEST=="online", ATTR{online}!="1", ATTR{online}="1"

%{ if trusted_ca_pem != null ~}
  - path: /usr/local/share/ca-certificates/trusted-ca.crt
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

      status "stage-0:os-prep"
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get upgrade -y
      apt-get install -y ca-certificates curl
      # br_netfilter and overlay ship as loadable modules on Ubuntu 26.04 but are
      # not auto-loaded. Without br_netfilter, bridge traffic bypasses iptables and
      # pod-to-service routing silently breaks.
      printf 'br_netfilter\noverlay\n' >/etc/modules-load.d/k3s.conf
      printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' >/etc/sysctl.d/99-k3s.conf
      modprobe br_netfilter
      modprobe overlay
      sysctl --system

      status "stage-1:os-trust"
      %{ if trusted_ca_pem != null ~}
      update-ca-certificates
      %{ endif ~}

      status "stage-2:registry-mirror"
      # No script action needed: the registry mirror config written above (when a mirror is set) is read by K3s at install time in stage-4.

      status "stage-3:selinux-prep"
      # Ubuntu uses AppArmor; k3s handles AppArmor automatically. No action needed.

      status "stage-4:k8s-install"
      %{ if node_role == "server-init" ~}
      TLS_SANS="--tls-san $NODE_IP"
      [ -n "$CLUSTER_FQDN" ] && TLS_SANS="$TLS_SANS --tls-san $CLUSTER_FQDN"
      export INSTALL_K3S_VERSION="${k8s_version}"
      export INSTALL_K3S_EXEC="server --cluster-init --secrets-encryption --disable traefik --disable-cloud-controller --node-ip $NODE_IP $TLS_SANS --write-kubeconfig-mode 0644${control_plane_taint ? " --node-taint CriticalAddonsOnly=true:NoExecute" : ""}"
      curl -sfL https://get.k3s.io | sh -
      %{ else ~}
      echo "[bootstrap] node_role=${node_role} is not implemented by this build of node-bootstrap" >&2
      status "FAILED:node-role-unimplemented"
      exit 1
      %{ endif ~}

      status "stage-5:k8s-wait"
      timeout 300 bash -c 'until kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get nodes --no-headers 2>/dev/null | grep -q " Ready"; do sleep 5; done'

      status "stage-6:argo-bootstrap"
      %{ if gitops_platform_repo_url != null ~}
      KC=/etc/rancher/k3s/k3s.yaml
      kubectl --kubeconfig "$KC" apply -f /etc/kube-node/manifests/00-argocd-helmchart.yaml
      echo "[bootstrap] waiting for argocd-server to be ready..."
      timeout 600 bash -c 'until kubectl --kubeconfig '"$KC"' -n argocd rollout status deployment/argocd-server --timeout=30s 2>/dev/null; do sleep 15; done'
      kubectl --kubeconfig "$KC" apply -f /etc/kube-node/manifests/10-platform-app.yaml
      %{ endif ~}

      status "stage-7:kubeconfig-publish"
      SERVER="$NODE_IP"; [ -n "$CLUSTER_FQDN" ] && SERVER="$CLUSTER_FQDN"
      sed "s|https://127.0.0.1:6443|https://$SERVER:6443|g" /etc/rancher/k3s/k3s.yaml >"$KUBECONFIG_OUT"
      chmod 0640 "$KUBECONFIG_OUT"
      chown root:ubuntu "$KUBECONFIG_OUT"

      status "complete"
      echo "[bootstrap] Bootstrap complete."

bootcmd:
  # systemd-networkd-wait-online has no timeout by default and waits for ALL managed
  # interfaces. Proxmox cloud-init generates a network-config that names the interface
  # "eth0", but Ubuntu 26.04 predictable naming keeps it as "ens18" (rename fails: busy).
  # networkd then waits forever for "eth0" to become routable, blocking network-online.target
  # and therefore cloud-final.service (runcmd). Stop and mask it here — the interface IS
  # already up by this point, so cloud-final can proceed safely.
  - [ systemctl, stop, systemd-networkd-wait-online.service ]
  - [ systemctl, mask, systemd-networkd-wait-online.service ]
runcmd:
  - ["/usr/local/bin/kube-node-bootstrap.sh"]
