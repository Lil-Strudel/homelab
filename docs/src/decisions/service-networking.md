# Service Networking

Why cluster `LoadBalancer` IPs are laid out the way they are: two pools inside their
VLANs, chosen by pinned IP, with public exposure fully built except the last mile.

## Pools live *inside* the VLAN subnets

The LB pools are slices of real VLANs — `internal-pool` = `10.69.60.64/26` (Trusted),
`public-pool` = `10.69.50.64/26` (DMZ) — not a dedicated out-of-band range. This makes
the address plan self-consistent: Trusted *is* the services VLAN (it only ever holds
services and the hosts that run them), and DMZ *is* where internet-facing services
belong. A service's exposure class is legible from its IP.

The cost is a known BGP/L2 quirk: an IP advertised via BGP that sits inside a VLAN's own
`/24` is unreachable from **other hosts on that same VLAN** — they see it as
directly-connected and ARP for it on the segment, where nothing answers (Cilium
announces it via BGP, not ARP). Everything **cross-VLAN** and over `wg-home` routes fine,
because the router prefers the more-specific BGP `/32` over the connected route.

## Accept the ARP trade-off; don't enable proxy-ARP

The fix would be `local-proxy-arp` on the VLAN interface (the router answers ARP for the
BGP `/32`s). We deliberately **don't**: neither Trusted nor DMZ holds hosts that reach LB
IPs *by IP* from the same segment (pods use ClusterIP/DNS, not the LB IP), so the quirk
never bites in practice. Enabling proxy-ARP would trade a non-problem for weaker L2
isolation and router-hairpinned intra-subnet traffic. If a real same-VLAN → LB-IP flow
ever appears, flipping `arp=local-proxy-arp` on that interface is the escape hatch.

## Pool = pinned IP, not a label

Cilium propagates `lbipam.cilium.io/*` annotations from an `Ingress` to its generated
Service, but **not** arbitrary labels — so pool selection can't rely on a label on an
ingress-backed service. Instead the pools carry **no `serviceSelector`** and have
disjoint CIDRs, and every service **pins** its IP (`lbipam.cilium.io/ips`). Membership
falls out of which CIDR the pinned IP is in. Pinning is required anyway, since the
Terraform `services` map needs a stable IP to write DNS against.

## Public exposure: everything but the last mile

Internet-facing services are built as if already exposed — a DMZ (`public-pool`) IP, a
`letsencrypt-prod` cert (DNS-01 needs no inbound), and split-horizon DNS wired in
Terraform. The **only** unbuilt piece is the internet last-mile: the tunnel / VPS and the
Route53 records that point at it. Those records are coded but **dormant** — gated on
`local.public_ingress_ip`, which is empty, so no public record is minted until a real
entry point exists. Flipping a service to public later is: stand up the tunnel to forward
`:443` → the service's DMZ IP, set `public_ingress_ip`, `terraform apply`.

This keeps the awkward, security-sensitive decision (how to expose to the internet) as an
isolated last step, while the whole internal pipeline is real and testable today.
