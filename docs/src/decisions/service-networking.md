# Service Networking

Why cluster `LoadBalancer` IPs are laid out the way they are: one pool, deliberately not
a VLAN, that exists on the network only as BGP `/32`s.

## The services range is not a VLAN

Every `LoadBalancer` IP comes from a single `CiliumLoadBalancerIPPool`, `services-pool`
(`kubernetes/infrastructure/configs/cilium/lb-pool.yaml`), spanning `10.69.65.1` through
`10.69.65.254`. `10.69.65.0/24` has no VLAN, no interface, no L2 segment, and no DHCP
server. Its only existence on the network is the set of `/32` routes Cilium advertises
over BGP from the Trusted-VLAN workers.

The pool is declared as a `start`/`stop` block rather than a bare CIDR so the network and
broadcast addresses stay out of the allocatable set — an unpinned service landing on
`10.69.65.0` routes fine over BGP but is a trap for anything that later treats the range
as a real subnet.

Three properties follow, and they are the reason for the layout:

- **No host anywhere treats a service IP as directly connected.** Every client — on any
  VLAN, including Trusted, and over WireGuard — routes to its gateway, which holds the
  `/32`. There is no segment on which a host could ARP for a service IP and get silence,
  so no `local-proxy-arp` escape hatch is needed and no VLAN's L2 isolation is weakened
  to serve one.
- **Firewall rules match on `dst-address`, never `out-interface`.** A packet to a service
  IP leaves the router via `Trusted_VLAN` toward the node holding the backend, so an
  `out-interface=Trusted_VLAN` rule would grant the *nodes* too — the Talos API, the
  Kubernetes API, the kubelet, and the Zigbee Pi. Matching the destination range grants
  exactly the services. See the [firewall matrix](../reference/network.md#firewall).
- **The range is only ever a destination.** Pod traffic leaves the cluster SNAT'd to a
  node address, so nothing on the network ever sources from `10.69.65.0/24` and no
  source-side rule references it.

## Exposure is a declaration, not an address

The pool carries no exposure meaning: an IP says nothing about whether a service faces
the internet. That decision lives in one field — `expose` on a service in `local.services`
(`terraform/main.tf`) — which drives the dst-nat rule, the forward rule, and the public
Route53 record together. A service that is not declared there cannot be reachable from
the WAN.

Every entry is `null` today. Nothing is exposed to the internet, and the DMZ VLAN is
empty.

Keeping exposure in a declaration rather than in the address plan is what makes it a
single, reviewable switch instead of an emergent property of which IP someone picked.

## Pin the IP; the services map is the allocation record

With one pool and no `serviceSelector`, allocation would work without pinning — but
every service pins anyway (`lbipam.cilium.io/ips`), because Terraform writes DNS against
a stable address and a re-allocated IP would silently break the record. Cilium propagates
`lbipam.cilium.io/*` annotations from an `Ingress` to its generated Service, so an
ingress-backed service carries the annotation on the `Ingress`.

`local.services` in `terraform/main.tf` is the allocation record: the one place to look
up which addresses are taken and the one place to claim a free one. Addresses are grouped
by role — platform services low, user-facing apps in the twenties and thirties,
observability in the forties — which is a convention for readability, not something
anything enforces.

## Raw L4 services bypass the Ingress entirely

Cilium's ingress controller is HTTP(S)-only, so anything speaking a non-HTTP protocol —
the Minecraft router on TCP `25565` and Factorio on UDP `34197` — cannot use it. Those get a
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

## The Shlink admin UI is its own everything

`admin.16e.link` has its own `Ingress`, its own IP, and its own certificate, entirely
separate from `16e.link` — not a second host on a shared Ingress. The
`shlink-web-client` SPA is fully client-side: `SHLINK_SERVER_API_KEY` is baked into what
the browser downloads, so anyone who can load the admin host holds an admin API key for
the Shlink instance.

Separating them means the short-link host can be published without any chance of the
admin host riding along on the same address or certificate. The short-link host is safe
to expose; the admin host is internal-only permanently, and would need real
authentication in front of it before that could change.
