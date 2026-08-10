# Network

The entire MikroTik network — router, switches, APs, VLANs, DHCP, BGP, WiFi, and the
firewall — is managed by Terraform. To stand it up, see
[Bootstrap → Network](../bootstrap/network.md). The BGP design (why two speakers, split
by role) is in
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
| 50 | DMZ | `10.69.50.0/24` | Reserved for an internet-facing edge; empty |
| 60 | Trusted | `10.69.60.0/24` | Kubernetes nodes + trusted hosts |
| 100 | Management | `10.69.100.0/24` | Network gear, OOB (KVM, UPS) |
| 200 | Dad | `10.69.200.0/24` | Separate household segment |

Within each `/24`, the address space is split by convention (set in
`terraform/modules/vlan`):

- **`.1`** — the router / gateway.
- **`.2`–`.127`** — static leases and VIPs.
- **`.128`–`.254`** — the DHCP dynamic pool.

Keeping the dynamic pool in the upper half means static assignments (nodes, the
kube-vip VIP, etc.) never collide with a DHCP lease.

Two ranges sit outside the VLAN scheme:

| Range | What it is |
| --- | --- |
| `10.69.65.0/24` | Cluster `LoadBalancer` service IPs — **not a VLAN**: no interface, no L2 segment, no DHCP. It exists only as BGP `/32`s. |
| `10.69.70.0/24`, `10.69.80.0/24` | The two WireGuard tunnels, each its own routed subnet. |

## Switching

Router `ether2–4` are trunk ports carrying all VLANs down to the switches. The
**core switch** (CRS326) aggregates SFP+ links; the **10G switch** (CRS312)
distributes 10G copper. Each switch has its own management IP on VLAN 100 and tags
node/uplink ports appropriately (Trusted for nodes, Management for gear).

Switches and access points run their own resolver pointed at the router
(`10.69.100.1`) with `allow-remote-requests` off — a client of the router's resolver, never
an open one on Management. That is what lets a switch resolve names for its own
outbound work, such as `check-for-updates`.

## WiFi

Two cAPax APs run under **CAPsMAN**, with AP1 as manager and AP2 as client, so the
`Strudel` SSID roams seamlessly across both. A second SSID, `SprinklerAct Studios`,
is a self-contained config on AP1 pinned to the Dad VLAN (200).

## BGP

All six nodes peer with the router over BGP (no ARP/L2 tricks). The router is
AS **65100**, the cluster is AS **65000**. One `CiliumLoadBalancerIPPool`,
`services-pool` (`cilium/lb-pool.yaml`), covers `10.69.65.1`–`10.69.65.254` and serves
every `LoadBalancer` service; kube-vip advertises the control-plane VIP separately.

Because the services range is not a VLAN, every host — on any segment, or over WireGuard
— reaches a service IP by routing to its gateway, which holds the `/32`. Nothing treats
a service address as directly connected. Why the range is laid out that way, and what it
implies for firewall rules, is in
[Decisions → Service Networking](../decisions/service-networking.md).

Each service **pins** its IP (`lbipam.cilium.io/ips`); `local.services` in
`terraform/main.tf` is the allocation record — the one place to look up a taken address
or claim a free one. The full BGP design (two speakers split by node role) is in
[Architecture → Load balancing](../architecture.md#load-balancing--the-control-plane-vip);
the router-side setup is in [Bootstrap → Network](../bootstrap/network.md).

## WireGuard / Remote Access

Two built-in WireGuard tunnels on the router provide roadwarrior VPN access from
anywhere. Both listen on the WAN and are reached at **`vpn.lilstrudel.io`**, whose address
is kept current by the [dynamic-DNS job](../operations/dns-and-certificates.md#dynamic-dns).
Because MikroTik WireGuard is L3-only, each tunnel is its own routed `/24` — a client is
*routed* toward a role, not bridged onto a VLAN's L2 segment — and its reach is set by
firewall rules that mirror that role.

| Tunnel | Subnet | Port | Role — reaches |
| --- | --- | --- | --- |
| `wg-home` | `10.69.70.0/24` | `51820/udp` | Personal / trusted devices (phone, etc.): Home, the services range `10.69.65.0/24`, internet. **No Trusted, no Management, no router admin.** |
| `wg-management` | `10.69.80.0/24` | `51821/udp` | Admin: every VLAN + full router access + internet. |

Adding a client is a day-2 task — see [Operations → VPN Access](../operations/vpn-access.md).

## Firewall

The router runs a **default-deny** policy in both `input` and `forward` — isolation comes
from the *absence* of an allow rule plus a catch-all drop, not from per-pair block rules.
It is enforced (`enforce_firewall = true` in `terraform/main.tf`).

The shape of it is a **user plane / admin plane split**. Home and `wg-home` reach cluster
*services* and nothing else of the cluster; the machinery behind those services — the
Talos API, the Kubernetes API, the kubelet, the Zigbee Pi, and every other host on
Trusted — is reachable only from Management and `wg-management`.

| From ↓ | Internet | Reaches | Notes |
| --- | --- | --- | --- |
| Home (10) | ✅ | `10.69.65.0/24` | services only — not the nodes that back them |
| Guest (20) | ✅ | — | fully isolated (also wants AP client isolation) |
| Security (30) | ❌ | — | fully isolated |
| IoT (40) | ❌ | — | fully isolated |
| DMZ (50) | ✅ | — | reserved for an internet-facing edge; nothing on it |
| Trusted (60) | ✅ | — | cluster nodes; pods reach services in-cluster, never through the router |
| Management (100) | ✅ | everything | the admin plane |
| Dad (200) | ✅ | — | isolated household segment |
| `wg-home` | ✅ | Home, `10.69.65.0/24` | user plane; no Trusted, no Management, no router admin |
| `wg-management` | ✅ | everything | admin plane; full router access |

The two service rules match on **`dst-address = 10.69.65.0/24`**, not on an out-interface.
Service traffic egresses via `Trusted_VLAN` toward whichever node holds the backend, so an
interface match would hand out the nodes along with the services. The range is never a
source — pod traffic leaves SNAT'd to a node address — so it needs no source-side rule.

Router **`input`** is locked to the Management VLAN and the `wg-management` tunnel. The
exceptions are the services a router has to answer for anyone: DHCP, DNS, and NTP from
every VLAN and both tunnels, ICMP, BGP from `Trusted_VLAN`, and the two WireGuard listen
ports from the WAN. That set is what keeps the policy from black-holing the network or
locking out the VPN.

### Router hardening

Beyond the filter policy, the router itself is trimmed to what is actually used:

| Setting | State | Why |
| --- | --- | --- |
| `telnet`, `ftp`, `www`, `api`, `api-ssl` | disabled | Unused management surfaces. |
| `winbox` (8291), `ssh`, `www-ssl` (6729) | kept | Winbox and SSH are the human paths; `www-ssl` is the REST endpoint every Terraform provider alias talks to. |
| MAC-server, MAC-Winbox, neighbour discovery | scoped to `Management_List` | MAC-level access stays as a recovery path for when IP routing is broken, but only from the segment that already has full router access. |
| Bandwidth-test server | off | Nothing uses it; it is a free DoS amplifier. |
| `tcp_syncookies` | on | Cheap SYN-flood protection on the router's own listeners. |
| `accept_redirects`, `accept_source_route` | off | Neither is legitimate traffic here. |
| `rp_filter` | `loose` | **Not strict:** BGP `/32`s and the kube-vip VIP make return paths legitimately asymmetric, which strict mode would drop. |

A `raw` prerouting chain handles WAN noise before connection tracking, so scans and floods
cost no conntrack state:

| Rule | Effect |
| --- | --- |
| drop UDP `53` from WAN | The resolver runs with `allow-remote-requests` for LAN clients; this makes sure it is never an open resolver. |
| accept ICMP from WAN, limited `10,20:packet` | Keeps ping and PMTUD working at a sane rate. |
| drop ICMP from WAN | Everything above that rate. |

The ICMP pair's order is load-bearing: the accept must precede the drop, or every WAN ICMP
packet is discarded instead of just the excess — which black-holes path-MTU discovery.

> The diagram source is editable — [`network-plan.drawio`](../assets/network-plan.drawio).
