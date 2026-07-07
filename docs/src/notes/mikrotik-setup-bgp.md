# MikroTik BGP Setup

Two cluster BGP speakers advertise to the router: **kube-vip** announces the
control-plane VIP (`10.69.60.10`) from the control-plane nodes, and **Cilium** announces
`LoadBalancer` service IPs from the worker nodes. The router side is intentionally simple.

On the MikroTik router, add a BGP connection **per node** (all six):

- **Remote AS:** `65100` (the router's own AS; the cluster is `65000`)
- **Remote address:** the node's IP — control plane `10.69.60.11`/`.12`/`.13`,
  workers `10.69.60.21`/`.22`/`.23`
- **Local role:** `ebgp`

That's it — once the cluster is up, the VIP route and the service pool
(`10.69.255.0/24`) `/32`s appear automatically.

> These BGP peers are also declared in Terraform (`bgp_peers` in `terraform/main.tf`),
> so they're recreated on a fresh apply. The cluster side lives in
> `kubernetes/infrastructure/controllers/kube-vip/` (VIP) and
> `kubernetes/infrastructure/configs/cilium/bgp.yaml` (services).
