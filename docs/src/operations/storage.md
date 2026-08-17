# Storage (Rook-Ceph)

In-cluster storage is [Rook](https://rook.io/)-managed [Ceph](https://ceph.com/),
backing PersistentVolumes with replicated block and shared-filesystem storage.
Versions are in [Reference → Versions](../reference/versions.md); the storage design
(OSD layout, replication, StorageClasses) is in
[Architecture → Storage](../architecture.md#storage); the value choices are in
[Decisions → Rook-Ceph Values](../decisions/rook-ceph.md).

There is **nothing to run by hand** — Flux brings the whole stack up from
`kubernetes/infrastructure/{controllers,configs}/rook-ceph/` once the cluster is
bootstrapped. This page is day-2: what runs, how to reach the dashboard, and how to
check health.

## What runs where

Rook v1.20 splits into three Helm charts, wired across the two Flux stages so nothing
races its CRDs:

| HelmRelease | Chart | Stage | Role |
| --- | --- | --- | --- |
| `ceph-operator` | `rook-ceph` | controllers | Operator + ceph-csi-operator subchart + all CRDs |
| `ceph-csi-drivers` | `ceph-csi-drivers` | controllers | RBD/CephFS `Driver` CRs (`dependsOn` the operator) |
| `ceph-cluster` | `rook-ceph-cluster` | configs | The `CephCluster` CR, pools, and StorageClasses |

`infra-controllers` runs with `wait: true`, so the operator and CSI drivers are healthy
before `infra-configs` reconciles the `CephCluster`.

## Fresh disks

Rook expects **empty** disks. A from-scratch bring-up gets them for free: the Talos
nuke (`talos/danger-reset-all-nodes.sh`) wipes `/dev/nvme0n1` on every node, and a
fresh Talos install leaves them clean — no stale OSD/LVM metadata for the OSD prepare
jobs to trip over. If you re-add a node without a wipe, clear the NVMe first.

## Secrets

None in git. Ceph generates its own keyring and mon/OSD keys in-cluster; Rook stores
them as Kubernetes Secrets it creates itself. There is nothing to SOPS-encrypt for Rook.

## Dashboard

The Ceph dashboard is enabled and reached at `https://ceph.lilstrudel.io`, through the
Cilium `Ingress` in `configs/rook-ceph/dashboard-ingress.yaml`. The Ingress pins
`10.69.65.10` (via `lbipam.cilium.io/ips`) from `services-pool`, which Cilium's BGP control
plane advertises to the MikroTik, and carries a Let's Encrypt certificate — see
[DNS & Certificates](./dns-and-certificates.md).

The mgr itself serves the dashboard over **plain HTTP on port 7000** (`dashboard.ssl:
false` on the `CephCluster`). TLS is terminated once, at the Ingress, with a certificate
browsers actually trust; the mgr's own certificate is self-signed and would not be. The
Ingress backs onto `rook-ceph-mgr-dashboard`, the Service Rook maintains against the
active mgr, so a mgr failover needs nothing here.

```bash
kubectl -n rook-ceph get ingress rook-ceph-dashboard
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in as `admin`.

## Health check

The toolbox is enabled for quick status checks:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

A healthy fresh cluster reports `HEALTH_OK`, 6 OSDs `up`/`in`, and 3 mons in quorum.
