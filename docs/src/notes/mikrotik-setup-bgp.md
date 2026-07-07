# MikroTik BGP Setup

**Cilium's BGP control plane** advertises `LoadBalancer` service IPs to the router over
BGP. (The control-plane VIP `10.69.60.10` is a Talos shared VIP and does *not* use BGP.)
The router side is intentionally simple.

On the MikroTik router, add a BGP connection **per control-plane node**:

- **Remote AS:** `65100` (the router's own AS; the cluster is `65000`)
- **Remote address:** the node's IP — `10.69.60.11`, `.12`, `.13`
- **Local role:** `ebgp`

That's it — once Cilium is up, routes for the service pool (`10.69.255.0/24`) appear
automatically as `/32`s.

> These BGP peers are also declared in Terraform (`bgp_peers` in `terraform/main.tf`),
> so they're recreated on a fresh apply. The cluster side lives in
> `kubernetes/main/kube-system/cilium/bgp.yaml`.
