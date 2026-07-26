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

## Raw L4 services bypass the Ingress entirely

Cilium's ingress controller is HTTP(S)-only, so anything speaking a non-HTTP protocol —
the game servers on TCP `25565` and UDP `34197` — cannot use it. Those get a
`type: LoadBalancer` Service carrying `lbipam.cilium.io/ips` **directly** (the shape
`rook-ceph/dashboard-lb.yaml` uses) rather than an `Ingress` that carries the annotation
for them. No `Ingress` also means no cert-manager and no TLS: there is nothing in a
Minecraft or Factorio handshake for a web certificate to secure.

These Services set **`externalTrafficPolicy: Local`**, which the HTTP services don't need
and don't set. Two reasons. It preserves the client source IP — the default `Cluster`
SNATs it to a node address, which would make a game server's own ban lists and logs
useless. And Cilium's BGP control plane only advertises a `Local` service's IP from nodes
that actually hold a backend, so the `/32` follows the pod instead of every worker
advertising and hairpinning traffic to whichever node has it. The catch: a node must be
a BGP speaker for its backend to be reachable at all. That holds because the speaker
`nodeSelector` covers exactly the non-control-plane nodes, and control planes are tainted
— so a pod can only land on a node that advertises. Untainting a control plane would
break it.

## A DMZ IP is a claim about intent, not a live exposure

The `public-pool` IP and the `public` flag in the Terraform `services` map are
independent, and the game servers use them apart: a DMZ IP so the eventual move to the
internet is only the last mile, with `public = false` so no Route53 record is minted yet.

They can't simply be flipped to `public = true` the way an HTTP service can.
`aws_route53_record.public` points every public service at one shared
`local.public_ingress_ip`, which assumes an HTTPS `:443` reverse proxy demultiplexing on
SNI. A distinct L4 port per service doesn't fit that record shape, so exposing these
needs its own path — a dst-nat rule, a WAN → DMZ forward rule ahead of the catch-all
drop, and a stable WAN address, none of which exist today.

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
