# Systems

The full hardware fleet — compute, network gear, storage, and out-of-band access.
IPs and roles match what Terraform provisions (DHCP reservations, BGP peers) in
[`terraform/main.tf`](https://github.com/Lil-Strudel/homelab/blob/main/terraform/main.tf).

## Compute — Kubernetes nodes

Six Dell OptiPlex Micros and one PowerEdge R730xd on VLAN 60 (Trusted). The control
plane shares a **kube-vip** VIP at `10.69.60.10`.

| Host | Model | IP | Role |
| --- | --- | --- | --- |
| `makima-1` | OptiPlex Micro 7070 | `10.69.60.11` | Control plane |
| `makima-2` | OptiPlex Micro 7070 | `10.69.60.12` | Control plane |
| `makima-3` | OptiPlex Micro 7070 | `10.69.60.13` | Control plane |
| `rem-1` | OptiPlex Micro 7080 | `10.69.60.21` | Worker |
| `rem-2` | OptiPlex Micro 7080 | `10.69.60.22` | Worker |
| `rem-3` | OptiPlex Micro 7080 | `10.69.60.23` | Worker |
| `rem-4` | PowerEdge R730xd | `10.69.60.24` | Worker, media node (ZFS + GPU) |
| — | kube-vip control-plane VIP | `10.69.60.10` | Control-plane endpoint |

Every Micro is kitted out identically:

| Component | Spec | Used for |
| --- | --- | --- |
| SATA SSD | 1× Samsung 870 250 GB | Talos OS — immutable install target |
| NVMe SSD | 1× 1 TB NVMe | Rook-Ceph OSD (`deviceFilter: ^nvme0n1`) |
| NIC | 1× 10 GbE (M.2/NVMe adapter) | Cluster + storage traffic |

The OS/disk split (Talos on the Samsung 870, Ceph on the NVMe) and the OSD layout
are covered in [Architecture → Storage](../architecture.md#storage).

rem-4, the R730xd:

| Component | Spec | Used for |
| --- | --- | --- |
| Rear SSDs | 2× Samsung 870 EVO 500 GB | Talos OS, on a software RAID 1 mirror |
| Front SSDs | 8× Samsung 870 EVO 1 TB | ZFS pool `phyllo`, raidz2 |
| Storage controller | PERC HBA330 Mini | Pass-through to every bay, no RAID |
| NIC | Intel X520 2× SFP+ / I350 2× 1G rNDC | Port 1 (10G) to the core switch; the rest unused |
| GPU | Intel Arc Pro A40 | Media transcoding (incl. AV1) |

Why it has no Ceph OSD, a software boot mirror, and an optics override is in
[Decisions → Media Node](../decisions/media-node.md).

## Network

| Device | Model | Mgmt IP | Role |
| --- | --- | --- | --- |
| Router | MikroTik CCR2004-16G-2S+ | `10.69.100.1` | WAN gateway, inter-VLAN routing, BGP (AS 65100) |
| Core switch | MikroTik CRS326-24S+2Q+RM | `10.69.100.10` | SFP+ aggregation |
| 10G switch | MikroTik CRS312-4C+8XG-RM | `10.69.100.11` | 10G copper distribution |
| Office switch | MikroTik CRS310-8G+2S+IN | `10.69.100.12` | Office desk ports |
| Access point 1 | MikroTik cAPax (cAPGi-5HaxD2HaxD) | `10.69.100.20` | CAPsMAN **manager** |
| Access point 2 | MikroTik cAPax (cAPGi-5HaxD2HaxD) | `10.69.100.21` | CAPsMAN **client** |

WiFi: a shared `Strudel` network, CAPsMAN-managed across both APs.

## Storage

| Device | Model | IP | Role |
| --- | --- | --- | --- |
| Zigbee controller | Raspberry Pi 4 (4 GB) + SONOFF ZBDongle-E | `10.69.60.30` | Home-automation radio |

Cluster storage is Rook-Ceph, one OSD per OptiPlex on the 1 TB NVMe (see
[Operations → Storage](../operations/storage.md)), plus the ZFS pool on rem-4 (see
[Operations → ZFS](../operations/zfs.md)).

## Out-of-band & power

| Device | Model | IP | Role |
| --- | --- | --- | --- |
| PiKVM | Raspberry Pi 4 (2 GB) | `10.69.100.30` | IP-KVM |
| rem-4 iDRAC | iDRAC8 | `10.69.100.32` | R730xd console, firmware, fans |
| KVM switch | TESmart 8-port | `10.69.100.13` | Physical KVM |
| UPS | APC SMT1000RM2UC | `10.69.100.77` | Battery backup |

## Upstream

The homelab hangs off a MikroTik router behind the house modem.

## Why this hardware

- **OptiPlex Micros** — cheap, quiet, low-power, plentiful used, and they take an
  M.2 + 2.5" SATA SSD. Six give a real 3+3 HA cluster in the footprint of a couple
  of books.
- **MikroTik everywhere** — full RouterOS API means the entire network is
  Terraformable; SFP+/10G without enterprise pricing.
- **R730xd** — many drive bays and spare PCIe slots, for bulk media storage
  that doesn't belong on the cluster's replicated Ceph tier, plus a GPU for transcoding.
- **PiKVM + TESmart + UPS** — headless recovery and clean shutdowns without walking
  to the rack.
