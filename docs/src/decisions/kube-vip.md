# kube-vip Manifest

[kube-vip](https://kube-vip.io/) owns the control-plane API VIP (`10.69.60.10`) and
advertises it over **BGP** from the control-plane nodes. It's deployed by Flux from
[`controllers/kube-vip/`](https://github.com/Lil-Strudel/homelab/tree/main/kubernetes/infrastructure/controllers/kube-vip),
which holds two committed files — `kube-vip.yaml` (the DaemonSet) and `rbac.yaml`.

Both are produced **verbatim** by the commands below, so re-running either shows zero
git diff. To change the config, edit the flags and re-run — **don't hand-edit or run a
formatter** over them, or they drift from the generator.

## Generating `kube-vip.yaml`

kube-vip ships a manifest generator in its image. We run `manifest daemonset`, then
apply two deterministic fixups — the BGP router ID, and the BGP timers:

Use the **kube-vip** version from [Reference → Versions](../reference/versions.md) as
the image tag (`<KUBE_VIP_VERSION>` below):

```bash
docker run --rm ghcr.io/kube-vip/kube-vip:<KUBE_VIP_VERSION> manifest daemonset \
  --interface lo --address 10.69.60.10 \
  --inCluster --taint --controlplane --bgp \
  --localAS 65000 --peerAS 65100 --peerAddress 10.69.60.1 \
| sed '/^        - name: bgp_routerid$/a\          valueFrom:\n            fieldRef:\n              fieldPath: status.podIP' \
| sed '/^        - manager$/a\        - --bgpHoldTimer=90 # 30s default outruns RouterOS'"'"'s keepalive timer — session drops every 30s\n        - --bgpKeepAliveInterval=30' \
> kubernetes/infrastructure/controllers/kube-vip/kube-vip.yaml
```

The tag is the version pin and is also the DaemonSet's image, so bumping it here (to the
version in the table) is the upgrade.

### Why these flags

| Flag | Sets | Purpose |
| --- | --- | --- |
| `--interface lo` | `vip_interface=lo` | Bind the VIP to **loopback** — published by BGP, not owned by a NIC. |
| `--address 10.69.60.10` | `address` | The control-plane API VIP. |
| `--inCluster` | `serviceAccountName` | Authenticate with the ServiceAccount token from `rbac.yaml`. |
| `--taint` | nodeAffinity + tolerations | One speaker per control-plane node, nowhere else. |
| `--controlplane` | `cp_enable=true` | Advertise the API VIP. |
| `--bgp` | `bgp_enable=true` | BGP mode — no ARP, no leader election. |
| `--localAS 65000` / `--peerAS 65100` / `--peerAddress 10.69.60.1` | `bgp_as` / `bgp_peeras` / `bgp_peeraddress` | Peer to the MikroTik. |

`--services` is **deliberately omitted** — `svc_enable` then defaults to `false`.

### The BGP router-ID fixup (the one edit)

The generator writes `bgp_routerid` with **no value**, and kube-vip passes the router
ID straight to gobgp with no defaulting. Every BGP speaker needs a *unique* router ID,
so the `sed` sets it per-pod from the pod IP via the downward API:

```yaml
- name: bgp_routerid
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
```

Its only option is a static `--bgpRouterID`, which would make all three control-plane
speakers advertise the *same* ID and collide.

### The BGP timer fixup (the other edit)

kube-vip defaults to a **30 s** hold timer. RouterOS leaves `keepalive-time` at its 3 m
default on the `routeros_routing_bgp_connection` peers, and at a 30 s negotiated hold it
sends nothing after the establishment burst — so kube-vip's hold timer expires, it emits
a `code (4,0)` NOTIFICATION, and the session is torn down and rebuilt on a ~37 s loop
(30 s hold + ~7 s reconnect).

That matters because the VIP has **no L2 fallback** — `vip_arp=false` on `lo` means BGP
is the only path to `10.69.60.10`. Each rebuild withdraws the route from that speaker,
and when the three coincide the route leaves the router's table entirely, dropping the
API VIP.

`--bgpHoldTimer=90` puts the control-plane peers on the same 90 s hold as Cilium's
worker peers, which are stable indefinitely against the same router;
`--bgpKeepAliveInterval=30` keeps the conventional hold/3 ratio.

The generator **accepts both flags and silently discards them** — it emits no
corresponding `env` entry — so they have to be appended to the container `args`, hence
the second `sed`. Verify a change landed by reading the negotiated hold back off the
router; it should report `1m30s`, not `30s`:

```bash
/routing/bgp/session/print where name~"Makima"
```

### Load-bearing details (don't "fix" these)

- **VIP on `lo` as a `/32` with `vip_arp=false`** — published purely over BGP; no
  gratuitous ARP. The `/32` (`vip_subnet=32`) is the IPv4 default.
- **`hostNetwork: true` + `NET_ADMIN`/`NET_RAW`** — kube-vip programs the loopback
  address and speaks BGP from the host network namespace.
- **Services OFF** — Cilium advertises `LoadBalancer` IPs from the **worker** nodes;
  keeping kube-vip's service LB off means the two speakers never collide on one node.
  See [Architecture → Load balancing](../architecture.md#load-balancing--the-control-plane-vip).
- **`node-role.kubernetes.io/master` nodeSelector term** — the generator still emits
  this legacy term alongside `…/control-plane`. They're OR'd, and Talos only sets the
  `control-plane` label (`master` was removed in k8s 1.24), so it matches nothing.
  Harmless — left as-is to keep the file pristine.

## `rbac.yaml`

Fetched verbatim from the kube-vip project's published manifest — the `ServiceAccount`
+ `ClusterRole` + `ClusterRoleBinding` the `--inCluster` token authenticates as:

```bash
curl -sL https://kube-vip.io/manifests/rbac.yaml \
  -o kubernetes/infrastructure/controllers/kube-vip/rbac.yaml
```

Committed byte-for-byte, so re-fetching shows zero diff.

## Deployed by Flux

Both files are listed in the kube-vip `kustomization.yaml`, enabled in the controllers
overlay **after** Cilium — kube-vip's pods need pod networking, which the CNI provides.
`infra-controllers` runs with `wait: true`, so it isn't Ready until the DaemonSet is
healthy.
