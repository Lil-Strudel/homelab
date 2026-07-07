# MikroTik BGP Setup

kube-vip advertises the control-plane VIP and `LoadBalancer` service IPs to the router
over BGP. The router side is intentionally simple.

On the MikroTik router, add a BGP connection **per control-plane node**:

- **Remote AS:** `65100` (the router's own AS; the cluster is `65000`)
- **Remote address:** the node's IP — `10.69.60.11`, `.12`, `.13`
- **Local role:** `ebgp`

That's it — once the nodes are up, routes for the VIP (`10.69.60.10`) and the service
pool (`10.69.60.100–110`) appear automatically.

> These BGP peers are also declared in Terraform (`bgp_peers` in `terraform/main.tf`),
> so they're recreated on a fresh apply.
