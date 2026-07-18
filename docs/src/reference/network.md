# Network

The entire MikroTik network — router, switches, APs, VLANs, DHCP, BGP, and WiFi — is
managed by Terraform. To stand it up, see [Bootstrap → Network](../bootstrap/network.md).
The BGP design (why two speakers, split by role) is in
[Architecture → Load balancing](../architecture.md#load-balancing--the-control-plane-vip).

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

Within each `/24`, the address space is split by convention (set in
`terraform/modules/vlan`):

- **`.1`** — the router / gateway.
- **`.2`–`.127`** — static leases, VIPs, and BGP-advertised ranges.
- **`.128`–`.254`** — the DHCP dynamic pool.

Keeping the dynamic pool in the upper half means static assignments (nodes, the
kube-vip VIP, etc.) never collide with a DHCP lease.

## Switching

Router `ether2–4` are trunk ports carrying all VLANs down to the switches. The
**core switch** (CRS326) aggregates SFP+ links; the **10G switch** (CRS312)
distributes 10G copper. Each switch has its own management IP on VLAN 100 and tags
node/uplink ports appropriately (Trusted for nodes, Management for gear).

## WiFi

Two cAPax APs run under **CAPsMAN**, with AP1 as manager and AP2 as client, so the
`Strudel` SSID roams seamlessly across both. A second SSID, `SprinklerAct Studios`,
is a self-contained config on AP1 pinned to the Dad VLAN (200).

## BGP

All six nodes peer with the router over BGP (no ARP/L2 tricks). The router is
AS **65100**, the cluster is AS **65000**, and the `LoadBalancer` pool is
`10.69.255.0/24` (set in `cilium/lb-pool.yaml`). The full design — two speakers
split by node role — is in
[Architecture → Load balancing](../architecture.md#load-balancing--the-control-plane-vip);
the router-side setup is in [Bootstrap → Network](../bootstrap/network.md).

## WireGuard / Remote Access

Two built-in WireGuard tunnels on the router provide roadwarrior VPN access from
anywhere. Both listen on the WAN and are reached at **`vpn.lilstrudel.io`**. Because
MikroTik WireGuard is L3-only, each tunnel is its own routed `/24` — a client is
*routed* toward a role, not bridged onto a VLAN's L2 segment — and its reach is set by
firewall rules that mirror that role.

| Tunnel | Subnet | Port | Role — reaches |
| --- | --- | --- | --- |
| `wg-home` | `10.69.70.0/24` | `51820/udp` | Personal / trusted devices (phone, etc.): Home, Trusted (cluster + `LoadBalancer` IPs `10.69.255.x`), DMZ, internet. **No Management, no router admin.** |
| `wg-management` | `10.69.80.0/24` | `51821/udp` | Admin: every VLAN + full router access + internet. |

Cluster `LoadBalancer` services (`10.69.255.x`) are reachable over `wg-home` via the
`wg-home → Trusted` rule, since those routes' next hops are Trusted-VLAN nodes.

Adding a client is a day-2 task — see [Operations → VPN Access](../operations/vpn-access.md).

## Firewall

The router runs a **default-deny** inter-VLAN policy — isolation comes from the
*absence* of an allow rule plus a catch-all drop, not from per-pair block rules.

| From ↓ | Internet | Reaches | Notes |
| --- | --- | --- | --- |
| Home (10) | ✅ | Trusted, DMZ | |
| Guest (20) | ✅ | — | fully isolated (also wants AP client isolation) |
| Security (30) | ❌ | — | fully isolated |
| IoT (40) | ❌ | — | fully isolated |
| DMZ (50) | ✅ | — | inbound port-forwards added later |
| Trusted (60) | ✅ | — | intra-cluster traffic is same-VLAN |
| Management (100) | ✅ | everything | |
| Dad (200) | ✅ | — | isolated household segment |
| `wg-home` | ✅ | Home, Trusted, DMZ | personal VPN; no Management/router admin |
| `wg-management` | ✅ | everything | admin VPN; full router access |

Router **`input`** is locked to the Management VLAN (and the `wg-management` tunnel) once
enforced, but DHCP, DNS, NTP, and BGP (from cluster nodes) are always permitted from
every VLAN — and the WireGuard listen ports from the WAN — so enabling the policy can't
black-hole the network or lock out the VPN.

> **Staging.** The catch-all drop rules are created **disabled** (`enforce_firewall =
> false` in `terraform/main.tf`). Apply once — nothing changes yet — verify each flow,
> then set `enforce_firewall = true` and apply again. Run Terraform from the
> Management VLAN, since enforcement restricts router admin to Management.

> The diagram source is editable — [`network-plan.drawio`](../assets/network-plan.drawio).
