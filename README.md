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
| `cluster_setup.sh` | Executable bash: OVS → k3s → Multus → OVS-CNI → KubeVirt (idempotent). `verify` subcommand runs the ping + flow dump. |
| `manifests.yaml` | One multi-doc YAML: `NetworkAttachmentDefinition` (ovs-cni) + two CirrOS `VirtualMachine`s on the OVS net. |
| `verification_flows.json` | Raw `ovs-ofctl dump-flows br-ovs --format=json`. **(PENDING live capture — see below.)** |
| `ping_results.txt` | Raw stdout of `ping` vm-a → vm-b over OVS. **(PENDING live capture.)** |
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

## Status of the two raw-output files
`verification_flows.json` and `ping_results.txt` are currently **PENDING** placeholders. They are
**not fabricated** — they are generated from the live cluster by `./cluster_setup.sh verify` and
will be overwritten with genuine output once the local environment (WSL2 Ubuntu + Docker) is up.
If VM boot under emulation proves too slow, the fallback (documented in `ASSUMPTIONS.md`) captures
the **same OVS datapath** using a plain pod's veth into `br-ovs` — the VM is only the vehicle; the
datapath is the objective.

## The design in one paragraph
`ovs-cni` plugs each VM's `bridge`-bound interface into a port on the host OVS bridge `br-ovs`.
A ping from `vm-a` (10.10.0.1) to `vm-b` (10.10.0.2) therefore traverses `br-ovs`, and
`ovs-ofctl dump-flows br-ovs` shows the flows. On BlueField-3 the *same* control plane stays put
while the datapath moves into the DPU eswitch (OVS-DOCA), reached by the guest via vDPA so it keeps
a stock `virtio-net` driver — see `dpu_offload_concept.md`.
