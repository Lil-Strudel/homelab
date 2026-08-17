# Dashboard (Dashy)

One page listing every service, device, and endpoint in the lab, at
**`https://dashy.lilstrudel.io`**. It is an ordinary workload in
`kubernetes/apps/main/dashy/` and carries the same hardening baseline as the rest of
[Applications](./applications.md).

There is **nothing to run by hand** — Flux brings it up. This page is day-2: how to change
what is on it, and why some tiles have a status dot and others do not.

## What is on it

| Section | Covers |
| --- | --- |
| Applications | Vaultwarden, Shlink, the Shlink admin UI, Dashy itself |
| Observability | Grafana, VictoriaMetrics, Loki, the two Alloy endpoints, the syslog sink |
| Storage | The Ceph dashboard and the NAS |
| Games | mc-router, the three Minecraft servers, Factorio |
| Network | Router, both switches, both access points, the WireGuard endpoint |
| Cluster | The Kubernetes API VIP and all six Talos nodes |
| Out-of-band | PiKVM, KVM switch, UPS, the Zigbee controller |
| Documentation | The repository and the reference pages |

Tiles whose endpoint is not HTTP — a Minecraft or Factorio address, a node's Talos API, the
syslog sink — open nothing. They are `target: clipboard`, so clicking copies the endpoint
instead of handing the browser a URL it cannot follow.

## Changing what is on it

`conf.yml` lives in `configmap.yaml` beside the manifests, and is mounted read-only at
`/app/user-data`. Editing tiles is a commit: change the ConfigMap, let Flux reconcile, and
reload the page — the kubelet refreshes the mounted file and the SPA re-fetches `conf.yml`
on load, so no pod restart is involved.

Editing through the UI is switched off (`preventWriteToDisk`). Git is the source of truth,
and a save that cannot reach the disk would only ever fail.

## Status checks

Dashy's status check is made by the **Dashy pod**, not the browser: the frontend calls the
server's `/status-check` endpoint, which makes the request. Every probed endpoint is
therefore a pod egress flow that the namespace's default-deny
`CiliumNetworkPolicy` has to allow, and the probe URLs are the targets'
**`ClusterIP` DNS names**, not their public hostnames — in-cluster traffic has no reason to
leave through an Ingress and come back.

Five endpoints are probed: Grafana, VictoriaMetrics, Loki, `alloy-syslog`, and the Ceph
dashboard. Everything else is deliberately left unchecked:

- **Vaultwarden, Shlink, Minecraft, Factorio** each run their own default-deny policy.
  Probing them would mean widening those policies to admit a dashboard — a new allowed
  flow into a password vault in exchange for a status dot.
- **Network gear, nodes, and out-of-band devices** sit on Management and Trusted, which
  the router's default-deny policy does not let a pod reach — see
  [Reference → Network](../reference/network.md#firewall).
- **Non-HTTP endpoints** have nothing to probe.

The pod has no internet egress at all, which is also why Dashy's update check is disabled:
it would only produce a warning in the log on every start.
