# Assignment 2 — The Cloud-Native OVS Datapath Challenge

**Candidate:** Vicky Sharma · github.com/vickysharma-prog
**Assignment:** https://github.com/sknrao/opi-assignment-2-2026

## What this is
A local Kubernetes lab that runs a **KubeVirt VM on an OVS-backed secondary network**, proves the
datapath with a real ping + OVS flow dump, and documents the shift to **BlueField-3 vDPA hardware
offload**.

**Topology:** k3s (single node) + a **native host OVS bridge** (`br-ovs`) + Multus CNI + OVS-CNI +
KubeVirt. OVS runs directly on the node, so the datapath we observe is real — not hidden inside a
nested container runtime. (This is the "configure a host OVS bridge" path the assignment allows.)

## Deliverables (exact filenames required)
| File | What it is |
|---|---|
| `cluster_setup.sh` | Executable bash: OVS (userspace) → k3s → Multus → OVS-CNI → KubeVirt, with the k3s CNI-path fixes. `verify` subcommand runs the ping + flow dump. **This is the exact procedure that ran.** |
| `manifests.yaml` | Multi-doc YAML: `NetworkAttachmentDefinition` (ovs-cni) + two CirrOS `VirtualMachine`s (the target) + two verification pods on the same OVS net. |
| `verification_flows.json` | **Real** OVS flows captured live: 1 OpenFlow flow + 5 datapath megaflows (ARP + ICMP, per-flow packet counters), raw text preserved. Serialized to JSON (OVS 3.x `ovs-ofctl` has no `--format=json`). |
| `ping_results.txt` | **Real** ping stdout — 10/10 packets, 0% loss, over `br-ovs`. |
| `dpu_offload_concept.md` | Software → hardware (BF3 vDPA / OVS-DOCA / switchdev) datapath shift, with diagrams + how to prove offload is real. |

Supporting: `ASSUMPTIONS.md`.

## How to run
```bash
chmod +x cluster_setup.sh
./cluster_setup.sh                    # bootstrap the whole stack
kubectl apply -f manifests.yaml       # deploy the OVS network + two CirrOS VMs
./cluster_setup.sh verify             # ping + dump flows -> writes ping_results.txt + verification_flows.json
```
Pinned versions: KubeVirt v1.8.4 · Multus v4.3.0 · OVS-CNI v0.39.0 · k3s v1.36.2. No `/dev/kvm`?
The script auto-enables KubeVirt software emulation (CirrOS still boots; slower).

## Status (honest summary)
Run end-to-end in a **GitHub Codespace** (local virtualization was unreliable). **The OVS datapath
is proven with real, live-captured output** (`ping_results.txt`, `verification_flows.json`) using
the **OVS-CNI pod path** — which the assignment explicitly allows ("configure a host OVS bridge").
**KubeVirt v1.8.4 was installed and the VM manifests scheduled**, but the free Codespace's **32 GB
disk** repeatedly hit `disk-pressure` and evicted the VM; the identical `manifests.yaml` boots on any
node with ~50 GB free disk (`/dev/kvm` is available there). Full detail — environment, the three
k3s CNI fixes, the VM stop-point, and how to finish it — is in `ASSUMPTIONS.md`.

## The design in one paragraph
`ovs-cni` plugs each VM's `bridge`-bound interface into a port on the host OVS bridge `br-ovs`.
A ping from `vm-a` (10.10.0.1) to `vm-b` (10.10.0.2) therefore traverses `br-ovs`, and
`ovs-ofctl dump-flows br-ovs` shows the flows. On BlueField-3 the *same* control plane stays put
while the datapath moves into the DPU eswitch (OVS-DOCA), reached by the guest via vDPA so it keeps
a stock `virtio-net` driver — see `dpu_offload_concept.md`.
