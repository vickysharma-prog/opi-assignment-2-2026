#!/usr/bin/env bash
#
# cluster_setup.sh — bootstrap a local Kubernetes datapath lab for the OPI OVS challenge.
#
# Stack: k3s (single node) + native host Open vSwitch bridge + Multus CNI + OVS-CNI + KubeVirt.
# Target host: Ubuntu 22.04/24.04 (incl. WSL2 Ubuntu). Run as a normal user with sudo.
#
# Why k3s + a NATIVE host OVS bridge (vs kind-in-a-container OVS): OVS runs directly on the node,
# so ovs-cni sees a real ovsdb socket and a real bridge — the datapath we want to observe is not
# hidden inside a nested container runtime. This is the "configure a host OVS bridge" option the
# assignment explicitly allows.
#
# Idempotent: safe to re-run. Each phase checks before acting.
#
# Usage:
#   ./cluster_setup.sh            # full bootstrap
#   ./cluster_setup.sh verify     # run ping + dump OVS flows (after 'kubectl apply -f manifests.yaml')
#
# Pinned versions (latest stable as of 2026-07-02):
KUBEVIRT_VERSION="${KUBEVIRT_VERSION:-v1.8.4}"
MULTUS_VERSION="${MULTUS_VERSION:-v4.3.0}"
OVS_CNI_VERSION="${OVS_CNI_VERSION:-v0.39.0}"
OVS_BRIDGE="${OVS_BRIDGE:-br-ovs}"          # the OVS bridge ovs-cni attaches pods/VMs to
VM_A_IP="${VM_A_IP:-10.10.0.1}"             # must match manifests.yaml cloud-init
VM_B_IP="${VM_B_IP:-10.10.0.2}"

set -euo pipefail
log()  { printf '\033[1;34m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[fail ]\033[0m %s\n' "$*" >&2; exit 1; }

# k3s ships kubectl and its own kubeconfig; export so this script and the user share one context.
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
KUBECTL="sudo k3s kubectl"

# ---------------------------------------------------------------------------
phase_ovs() {
  log "Phase 1/5: Open vSwitch (host datapath)"
  if ! command -v ovs-vsctl >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y openvswitch-switch
  fi
  # In WSL/plain hosts systemd may be absent; start the DB + switch daemons directly if needed.
  if ! sudo ovs-vsctl show >/dev/null 2>&1; then
    sudo /usr/share/openvswitch/scripts/ovs-ctl start || sudo service openvswitch-switch start
  fi
  if ! sudo ovs-vsctl br-exists "$OVS_BRIDGE"; then
    sudo ovs-vsctl add-br "$OVS_BRIDGE"
    log "created OVS bridge $OVS_BRIDGE"
  else
    log "OVS bridge $OVS_BRIDGE already present"
  fi
  sudo ip link set "$OVS_BRIDGE" up
  sudo ovs-vsctl show
}

# ---------------------------------------------------------------------------
phase_k3s() {
  log "Phase 2/5: k3s single-node cluster"
  if ! command -v k3s >/dev/null 2>&1; then
    # --flannel-backend keeps a working default pod network; Multus layers OVS as a SECONDARY net.
    # --disable traefik/servicelb: not needed for this lab.
    curl -sfL https://get.k3s.io | sudo sh -s - \
      --write-kubeconfig-mode 644 \
      --disable traefik --disable servicelb
  fi
  log "waiting for node Ready..."
  timeout 120 bash -c "until $KUBECTL get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done" \
    || die "k3s node did not become Ready"
  $KUBECTL get nodes -o wide
}

# ---------------------------------------------------------------------------
phase_multus() {
  log "Phase 3/5: Multus CNI (thick daemonset)"
  # k3s keeps CNI conf/bin under /var/lib/rancher/k3s/... — Multus must be pointed there.
  local url="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml"
  $KUBECTL apply -f "$url"
  # Point Multus at the k3s CNI directories (default manifest assumes /etc/cni/net.d + /opt/cni/bin).
  $KUBECTL -n kube-system patch daemonset kube-multus-ds --type=json -p='[
    {"op":"replace","path":"/spec/template/spec/volumes","value":[
      {"name":"cni","hostPath":{"path":"/var/lib/rancher/k3s/agent/etc/cni/net.d"}},
      {"name":"cnibin","hostPath":{"path":"/var/lib/rancher/k3s/data/current/bin"}},
      {"name":"host-run","hostPath":{"path":"/run"}},
      {"name":"host-var-lib-cni-multus","hostPath":{"path":"/var/lib/cni/multus"}},
      {"name":"host-var-lib-kubelet","hostPath":{"path":"/var/lib/kubelet"}},
      {"name":"host-run-k8s-cni-cncf-io","hostPath":{"path":"/run/k8s.cni.cncf.io"}},
      {"name":"host-run-netns","hostPath":{"path":"/run/netns/"}},
      {"name":"multus-conf-dir","hostPath":{"path":"/var/lib/rancher/k3s/agent/etc/cni/net.d/multus.d"}},
      {"name":"multus-socket-dir-parent","hostPath":{"path":"/run/multus"}}
    ]}
  ]' 2>/dev/null || warn "multus volume patch skipped (verify CNI paths manually if pods fail to schedule)"
  $KUBECTL -n kube-system rollout status daemonset/kube-multus-ds --timeout=180s || \
    warn "multus rollout slow; continuing"
}

# ---------------------------------------------------------------------------
phase_ovs_cni() {
  log "Phase 4/5: OVS-CNI (plugin + marker daemonset)"
  local url="https://raw.githubusercontent.com/k8snetworkplumbingwg/ovs-cni/${OVS_CNI_VERSION}/examples/ovs-cni.yml"
  $KUBECTL apply -f "$url"
  # ovs-cni copies its binary to the CNI bin dir; on k3s ensure it lands where kubelet looks.
  $KUBECTL -n kube-system rollout status daemonset/ovs-cni-amd64 --timeout=180s 2>/dev/null || \
    warn "ovs-cni rollout slow/renamed; check: $KUBECTL -n kube-system get ds | grep ovs"
}

# ---------------------------------------------------------------------------
phase_kubevirt() {
  log "Phase 5/5: KubeVirt ${KUBEVIRT_VERSION}"
  $KUBECTL apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
  $KUBECTL apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"

  # No hardware virtualization (/dev/kvm) => enable software emulation so CirrOS still boots.
  if [ ! -e /dev/kvm ]; then
    warn "/dev/kvm not present — enabling KubeVirt software emulation (QEMU TCG; slower but valid)"
    $KUBECTL -n kubevirt patch kubevirt kubevirt --type=merge -p \
      '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
  else
    log "/dev/kvm present — using hardware-accelerated virtualization"
  fi

  log "waiting for KubeVirt to become Available (this can take several minutes)..."
  $KUBECTL -n kubevirt wait kv kubevirt --for=condition=Available --timeout=600s \
    || warn "KubeVirt not Available yet; check: $KUBECTL -n kubevirt get kv -o yaml"
  $KUBECTL -n kubevirt get pods
}

# ---------------------------------------------------------------------------
# verify: run the datapath test and produce the two raw-output deliverables.
verify() {
  log "Datapath verification"
  log "waiting for both VMs to report Running..."
  timeout 600 bash -c "until [ \$($KUBECTL get vmi --no-headers 2>/dev/null | grep -c Running) -ge 2 ]; do sleep 5; done" \
    || warn "VMs not both Running; check: $KUBECTL get vmi"

  # CirrOS default creds: cirros / gocubsgo. virtctl console is interactive; we drive the ping
  # via the guest agent / console script. Simplest robust capture: ping from vm-a to vm-b.
  log "pinging ${VM_B_IP} from vm-a over the OVS secondary interface..."
  # Requires virtctl (installed below if missing). Uses expect-free console piping.
  ping_out=$(sudo virtctl console vm-a --timeout=1 <<EOF 2>/dev/null || true
ping -c 4 ${VM_B_IP}
EOF
)
  {
    echo "# ping test: vm-a (${VM_A_IP}) -> vm-b (${VM_B_IP}) over OVS bridge ${OVS_BRIDGE}"
    echo "# captured: $(date -u +%FT%TZ)"
    echo "$ping_out"
  } | tee ping_results.txt

  log "dumping OVS flows on ${OVS_BRIDGE} as JSON..."
  sudo ovs-ofctl dump-flows "$OVS_BRIDGE" --format=json | tee verification_flows.json >/dev/null
  echo "wrote verification_flows.json ($(wc -c < verification_flows.json) bytes)"
  log "also useful (offloaded datapath view): sudo ovs-appctl dpctl/dump-flows -m"
}

install_virtctl() {
  command -v virtctl >/dev/null 2>&1 && return 0
  local u="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
  sudo curl -L "$u" -o /usr/local/bin/virtctl && sudo chmod +x /usr/local/bin/virtctl
}

main() {
  case "${1:-all}" in
    verify) install_virtctl; verify ;;
    all)
      [ "$(id -u)" -eq 0 ] && die "run as a normal user with sudo, not root"
      phase_ovs
      phase_k3s
      phase_multus
      phase_ovs_cni
      phase_kubevirt
      install_virtctl
      log "bootstrap complete."
      log "next: $KUBECTL apply -f manifests.yaml   then:   ./cluster_setup.sh verify"
      ;;
    *) die "unknown arg: $1 (use: all | verify)" ;;
  esac
}
main "${1:-all}"
