# Network

The entire MikroTik network — router, switches, APs, VLANs, DHCP, BGP, and WiFi — is
managed by Terraform. See [Controlling MikroTik with Terraform](./controlling-mikrotik-with-terraform.md).

![Network Plan](../assets/network-plan.png)

## Addressing

Everything lives under `10.69.0.0/16`. Each VLAN gets its own `/24`, numbered by VLAN
ID: **`10.69.<vlan>.0/24`**, with the router as `.1`.

| VLAN | Name | Subnet | Purpose |
| --- | --- | --- | --- |
| 10 | Home | `10.69.10.0/24` | Personal devices |
| 20 | Guest | `10.69.20.0/24` | Isolated guest access |
| 30 | Security | `10.69.30.0/24` | Cameras / surveillance |
| 40 | IoT | `10.69.40.0/24` | Smart-home / untrusted IoT |
| 50 | DMZ | `10.69.50.0/24` | Externally exposed services |
| 60 | Trusted | `10.69.60.0/24` | Kubernetes nodes + trusted hosts |
| 100 | Management | `10.69.100.0/24` | Network gear, OOB (KVM, UPS) |
| 200 | Dad | `10.69.200.0/24` | Separate household segment |

## Switching

Router `ether2–4` are trunk ports carrying all VLANs down to the switches. The
**core switch** (CRS326) aggregates SFP+ links; the **10G switch** (CRS312)
distributes 10G copper. Each switch has its own management IP on VLAN 100 and tags
node/uplink ports appropriately (Trusted for nodes, Management for gear).

## WiFi

Two cAPax APs run under **CAPsMAN**, with AP1 as manager and AP2 as client, so the
`Strudel` SSID roams seamlessly across both. A second SSID, `SprinklerAct Studios`,
is a self-contained config on AP1 pinned to the Dad VLAN (200).

## BGP — where the cluster meets the network

The Kubernetes control-plane nodes peer with the router over BGP so that kube-vip can
advertise service and control-plane IPs directly into the routing table (no ARP/L2
tricks).

- **Router** — AS **65100**, peering to each control-plane node.
- **Cluster (kube-vip)** — AS **65000**, router ID per node.
- **Peers** — `makima-1` (`.11`), `makima-2` (`.12`), `makima-3` (`.13`).
- **LoadBalancer pool** — `10.69.60.100–110`.

Setup notes: [MikroTik BGP Setup](./mikrotik-setup-bgp.md).

> The diagram source is editable — [`network-plan.drawio`](../assets/network-plan.drawio).
