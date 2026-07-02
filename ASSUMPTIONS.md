# Assumptions & Decisions — Assignment 2

Per the assignment rule: *"Do not ask clarifying questions… make a reasonable assumption, document
it in your submission, and move forward."* This is that record.

| # | Ambiguity | Assumption / decision | Rationale |
|---|---|---|---|
| 1 | Cluster flavor (KinD / Minikube / k3s) | **k3s**, single node | Lets OVS run **natively on the host** so ovs-cni sees a real bridge/ovsdb — the datapath isn't buried in a nested container runtime (as it would be with kind-in-a-container OVS). |
| 2 | OVS-CNI plugin vs host bridge + veth | **OVS-CNI onto a native host bridge `br-ovs`** | The assignment explicitly allows "configure a host OVS bridge"; this is the cleanest, most datapath-honest option and generalizes best to the BF3 story. |
| 3 | How the VM attaches | KubeVirt `bridge` binding on a **Multus** secondary net backed by the ovs-cni `NetworkAttachmentDefinition` | Standard KubeVirt + Multus + ovs-cni pattern; keeps the primary pod network (masquerade) for boot/console. |
| 4 | What to ping | **Two CirrOS VMs** (vm-a 10.10.0.1 ↔ vm-b 10.10.0.2) on the OVS net | Guarantees the traffic traverses `br-ovs` (both ports on the same bridge), which is exactly what the flow dump must show. |
| 5 | No hardware virtualization (`/dev/kvm`) | Auto-enable KubeVirt **`useEmulation: true`** (QEMU TCG) | The lab host (Windows 11 + WSL2) has unreliable nested KVM; emulation still boots CirrOS and the **datapath** (the graded objective) is unaffected by VM speed. |
| 6 | Version pinning | KubeVirt v1.8.4 · Multus v4.3.0 · OVS-CNI v0.39.0 · k3s v1.36.2 | Latest stable as of 2026-07-02 (verified via GitHub releases); pinned for reproducibility, overridable via env vars in `cluster_setup.sh`. |
| 7 | k3s CNI paths | Multus/ovs-cni pointed at k3s dirs (`/var/lib/rancher/k3s/...`) | k3s does not use `/etc/cni/net.d` + `/opt/cni/bin`; the script patches the Multus daemonset accordingly. Final path tuning is confirmed at runtime. |

## Graceful-degradation ladder (each rung still yields the named files)
The assignment values **approach over perfection** and accepts partial work with a note. If a rung
fails, we drop to the next and document it here:

1. **Best (primary):** CirrOS VM on OVS secondary net; real ping; real `dump-flows --format=json`.
2. **If VM won't boot / emulation too slow:** a plain **pod** with a veth into `br-ovs` performs the
   ping; capture those flows. *The datapath is the objective; the VM is only the vehicle.*
3. **If OVS-CNI won't integrate on k3s:** manually wire a **veth pair** into `br-ovs`
   (`ovs-vsctl add-port`), ping across it, capture flows; document the manual step.

`dpu_offload_concept.md` is pure documentation and is **complete regardless of which rung is reached.**

## Current status (2026-07-02)
- Environment-independent deliverables (`cluster_setup.sh`, `manifests.yaml`, `dpu_offload_concept.md`)
  are **written and validated** (bash `-n` clean; YAML parses to 3 docs; NAD config is valid JSON;
  both concept diagrams render to SVG).
- `verification_flows.json` + `ping_results.txt` are **PENDING** placeholders, to be overwritten with
  genuine captures once WSL2 Ubuntu + Docker are running on the host. **Not fabricated.**
