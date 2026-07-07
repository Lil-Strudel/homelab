# Systems

The full hardware fleet — compute, network gear, storage, and out-of-band access.
IPs and roles below match what Terraform actually provisions (DHCP reservations, BGP
peers) in [`terraform/main.tf`](https://github.com/Lil-Strudel/homelab/blob/main/terraform/main.tf).

## Compute — Kubernetes nodes

Six Dell OptiPlex Micros on VLAN 60 (Trusted). The control plane shares a kube-vip
VIP at `10.69.60.10`.

| Host | Model | IP | Role |
| --- | --- | --- | --- |
| `makima-1` | OptiPlex Micro 7070 | `10.69.60.11` | Control plane |
| `makima-2` | OptiPlex Micro 7070 | `10.69.60.12` | Control plane |
| `makima-3` | OptiPlex Micro 7070 | `10.69.60.13` | Control plane |
| `rem-1` | OptiPlex Micro 7080 | `10.69.60.21` | Worker |
| `rem-2` | OptiPlex Micro 7080 | `10.69.60.22` | Worker |
| `rem-3` | OptiPlex Micro 7080 | `10.69.60.23` | Worker |
| — | (kube-vip VIP) | `10.69.60.10` | Control-plane endpoint |

### Per-node storage & networking

Every Micro (control plane and worker alike) is kitted out identically:

| Component | Spec | Used for |
| --- | --- | --- |
| SATA SSD | 1× Samsung 870 250 GB | Talos OS — immutable install target |
| NVMe SSD | 1× 1 TB NVMe | Rook-Ceph OSD (`deviceFilter: ^nvme0n1`) |
| NIC | 1× 10 GbE (M.2/NVMe adapter) | Cluster + storage traffic |

Talos boots **Secure Boot** and installs to the **250 GB Samsung SSD 870**, selected by
disk **model** (`Samsung SSD 870`) in `talos/patch.yaml` so the OS never lands on the
1 TB NVMe. The NVMe is left whole for Ceph, which claims it via `deviceFilter: ^nvme0n1` —
so all six nodes contribute one OSD each (3× replicated, `host` failure domain).

## Network

| Device | Model | Mgmt IP | Role |
| --- | --- | --- | --- |
| Router | MikroTik CCR2004-16G-2S+ | `10.69.100.1` | WAN gateway, inter-VLAN routing, BGP (AS 65100) |
| Core switch | MikroTik CRS326-24S+2Q+RM | `10.69.100.10` | SFP+ aggregation |
| 10G switch | MikroTik CRS312-4C+8XG-RM | `10.69.100.11` | 10G copper distribution |
| Access point 1 | MikroTik cAPax (cAPGi-5HaxD2HaxD) | `10.69.100.20` | CAPsMAN **manager** |
| Access point 2 | MikroTik cAPax (cAPGi-5HaxD2HaxD) | `10.69.100.21` | CAPsMAN **client** |

WiFi: a shared `Strudel` network (CAPsMAN-managed across both APs) plus a
self-contained `SprinklerAct Studios` SSID pinned to the Dad VLAN on AP1.

## Storage

| Device | Model | IP | Role |
| --- | --- | --- | --- |
| NAS | Dell PowerEdge R730xd | `10.69.100.32` | Bulk storage (media, backups) |
| Zigbee controller | Raspberry Pi 4 (4 GB) + SONOFF ZBDongle-E | `10.69.60.30` | Home-automation radio |

The R730xd carries **8× 1 TB Samsung 870** SSDs split across **two ZFS pools**, served
as bulk/NFS storage outside the cluster. In-cluster storage is handled separately by
**Rook-Ceph**, one OSD per node on the 1 TB NVMe (see
[Per-node storage & networking](#per-node-storage--networking)).

## Out-of-band & power

| Device | Model | IP | Role |
| --- | --- | --- | --- |
| PiKVM | Raspberry Pi 4 (2 GB) | `10.69.100.30` | IP-KVM |
| KVM switch | TESmart 8-port | `10.69.100.13` | Physical KVM |
| UPS | APC SMT1000RM2UC | `10.69.100.77` | Battery backup |

## Upstream

The homelab hangs off a MikroTik router behind the house modem. A separate Netgear
router (VLAN 200, "Dad") is bridged in for a non-homelab network segment.

## Why this hardware

- **OptiPlex Micros** — cheap, quiet, low-power, plentiful on the used market, and
  they take an M.2 + 2.5" SATA SSD. Six of them give a real 3+3 HA cluster in the
  footprint of a couple of books.
- **MikroTik everywhere** — full RouterOS API means the entire network is
  Terraformable; SFP+/10G on the switches without enterprise pricing.
- **R730xd** — lots of 3.5" bays for cheap bulk storage that doesn't belong on the
  cluster's fast Ceph tier.
- **PiKVM + TESmart + UPS** — headless recovery and clean shutdowns without walking
  to the rack.
