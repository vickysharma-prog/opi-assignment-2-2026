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

## What actually ran (2026-07-02) — environment & results

The local laptop's virtualization was unreliable (WSL/Docker wouldn't stay up), so the lab was run
end-to-end in a **GitHub Codespace** (Ubuntu 24.04, kernel 6.8, 4 vCPU / 16 GB, **32 GB disk**,
containerised — no loadable kernel modules). Consequences and outcomes:

- **OVS** runs in **userspace datapath mode** (`datapath_type=netdev`) because `openvswitch.ko`
  can't be loaded in a container. `ovs-vswitchd` runs fine this way. ✔
- **k3s** required `--snapshotter=native` (overlay-on-overlay otherwise fails) and was run detached
  (no systemd in the container). Node came up Ready. ✔
- **Multus + OVS-CNI** needed three k3s-specific fixes, all encoded in `cluster_setup.sh`:
  (1) `mount --make-rshared /` (Multus binary-installer uses bidirectional mount propagation);
  (2) repoint the daemonset hostPaths to k3s CNI conf/bin dirs;
  (3) copy the real `multus`/`ovs` binaries into `/var/lib/rancher/k3s/data/cni` (the dir containerd
  actually invokes) and symlink `/etc/cni/net.d` so Multus' kubeconfig path resolves. ✔
- **Datapath PROVEN with pods (rung 2 of the ladder below):** two pods on `ovs-net`, ping
  **10/10, 0% loss**, with real OpenFlow + datapath megaflows (ARP + ICMP, per-flow packet
  counters) — these are `ping_results.txt` and `verification_flows.json`. **Real, not fabricated.** ✔

### KubeVirt VM (assignment's ideal) — attempted, where it stopped, and how to finish
- **KubeVirt v1.8.4 was installed** (operator + all control-plane pods Available) and the CirrOS
  `VirtualMachine`s in `manifests.yaml` were applied and **scheduled**.
- **Stop point:** the Codespace's **32 GB disk** is ~75 % full just from the k8s + KubeVirt images
  (~15 GB). A booting VM's disk overlay tips the node into **`disk-pressure`**, whose `NoSchedule`
  taint **evicts the VM** — a loop that even a single VM couldn't escape on this node. (A second,
  time-related snag also appeared after ~1.5 h: Multus' short-lived SA token expired, giving
  `error waiting for pod: Unauthorized` on new sandboxes — fixed by restarting the Multus daemonset.)
- **How I'd complete it:** run the *identical* `manifests.yaml` on a node with **≥ ~50 GB free disk**
  (a normal VM/bare-metal, or a Codespace with a larger disk). With `/dev/kvm` present (it is, on the
  Codespace host) KubeVirt runs hardware-accelerated and CirrOS boots in well under a minute. No
  manifest changes are needed — only more disk. The `verify` step then captures the VM-based ping
  and the same flow dump.

Per the assignment's stated philosophy ("Approach > Perfection … submit what you have with a note on
where you stopped, why, and how you'd proceed"), the submission ships the **real pod-based datapath
result** plus the **ready-to-run VM manifests** and this note.
