# Creating the kube-vip Manifest

[kube-vip](https://kube-vip.io/) owns the control-plane API VIP (`10.69.60.10`) and
advertises it over **BGP** from the control-plane nodes. It's deployed by Flux from
[`kubernetes/infrastructure/controllers/kube-vip/`](https://github.com/Lil-Strudel/homelab/tree/main/kubernetes/infrastructure/controllers/kube-vip),
which holds two committed files — `kube-vip.yaml` (the DaemonSet) and `rbac.yaml`.

Both are produced verbatim by the commands below and committed as-is, so **re-running
either command shows zero git diff**. To change the config, edit the flags and re-run —
don't hand-edit the files or run a YAML formatter over them, or they'll drift from the
generator.

## The DaemonSet — `kube-vip.yaml`

kube-vip ships a manifest generator in its container image (see the upstream
[DaemonSet install guide](https://kube-vip.io/docs/installation/daemonset/)). We run
`manifest daemonset`, then apply one deterministic fixup for the BGP router ID:

```bash
docker run --rm ghcr.io/kube-vip/kube-vip:v1.2.1 manifest daemonset \
  --interface lo --address 10.69.60.10 \
  --inCluster --taint --controlplane --bgp \
  --localAS 65000 --peerAS 65100 --peerAddress 10.69.60.1 \
| sed '/^        - name: bgp_routerid$/a\          valueFrom:\n            fieldRef:\n              fieldPath: status.podIP' \
> kubernetes/infrastructure/controllers/kube-vip/kube-vip.yaml
```

The image tag is the version pin — it's also the DaemonSet's image, so bump it here to
upgrade kube-vip. `v1.2.1` is the current latest release. (The upstream docs wrap this in
a `ctr`/`docker` shell alias; plain `docker run` is the same thing.)

### Why these flags

| Flag | Sets env | Purpose |
| --- | --- | --- |
| `--interface lo` | `vip_interface=lo` | Bind the VIP to **loopback** — it's published by BGP, not owned by a real NIC. |
| `--address 10.69.60.10` | `address` | The control-plane API VIP. |
| `--inCluster` | `serviceAccountName: kube-vip` | Authenticate with the ServiceAccount token from `rbac.yaml` (not `admin.conf`). |
| `--taint` | nodeAffinity + tolerations | Run one speaker on every control-plane node, and nowhere else. |
| `--controlplane` | `cp_enable=true` | Advertise the API VIP. |
| `--bgp` | `bgp_enable=true` | BGP mode — no ARP, no leader election. |
| `--localAS 65000` | `bgp_as` | Our AS; peers to the MikroTik... |
| `--peerAS 65100` | `bgp_peeras` | ...at AS 65100... |
| `--peerAddress 10.69.60.1` | `bgp_peeraddress` | ...reachable at `10.69.60.1`. |

`--services` is **deliberately omitted** — `svc_enable` then defaults to `false`.

### The BGP router-ID fixup (the one edit)

The generator writes `bgp_routerid` with **no value**, and kube-vip passes the router ID
straight to gobgp with no defaulting (`pkg/manager`, `pkg/bgp/server.go`). Every BGP
speaker needs a *unique* router ID, so the `sed` sets it per-pod from the pod IP via the
downward API:

```yaml
- name: bgp_routerid
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
```

This is the only thing the generator can't express — its only option is a static
`--bgpRouterID`, which would make all three control-plane speakers advertise the *same*
ID and collide.

### Load-bearing details (don't "fix" these)

- **VIP on `lo` as a `/32` with `vip_arp=false`** — the route is published purely over
  BGP; no gratuitous ARP. The `/32` (`vip_subnet=32`) is the IPv4 default.
- **`hostNetwork: true` + `NET_ADMIN`/`NET_RAW`** — kube-vip programs the loopback
  address and speaks BGP from the host network namespace.
- **Services OFF** (`svc_enable` absent → `false`) — Cilium's BGP control plane advertises
  `LoadBalancer` IPs from the **worker** nodes. Keeping kube-vip's service LB off means the
  two BGP speakers never collide on one node (both peer AS 65000 → AS 65100 at
  `10.69.60.1`). See [Architecture → the control-plane VIP](../architecture.md#load-balancing--the-control-plane-vip).
- **`node-role.kubernetes.io/master` nodeSelector term** — the generator still emits this
  legacy term *alongside* `…/control-plane`. They're OR'd, and Talos only sets the
  `control-plane` label (`master` was removed in Kubernetes 1.24), so the `master` term
  matches nothing. Harmless — left as-is to keep the file pristine.

## RBAC — `rbac.yaml`

Fetched verbatim from the kube-vip project's published manifest — the same source the
[install docs](https://kube-vip.io/docs/installation/daemonset/) point `kubectl apply`
at:

```bash
curl -sL https://kube-vip.io/manifests/rbac.yaml \
  -o kubernetes/infrastructure/controllers/kube-vip/rbac.yaml
```

It's the `ServiceAccount` + `ClusterRole` + `ClusterRoleBinding` that the DaemonSet's
`--inCluster` token authenticates as (watch/update on nodes, services, endpoints, leases).
Committed byte-for-byte, so re-fetching shows zero diff.

## Deployed by Flux

Both files are listed in the kube-vip `kustomization.yaml`, and kube-vip is enabled in the
controllers overlay
([`kubernetes/infrastructure/controllers/kustomization.yaml`](https://github.com/Lil-Strudel/homelab/tree/main/kubernetes/infrastructure/controllers))
**after** cilium — kube-vip's pods need pod networking, which the CNI provides. Flux's
`infra-controllers` Kustomization applies them; with `wait: true` it isn't Ready until the
DaemonSet is healthy.
