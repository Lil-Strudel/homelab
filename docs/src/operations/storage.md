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

The Ceph dashboard is enabled (HTTPS) and exposed on the LAN by
`configs/rook-ceph/dashboard-lb.yaml` — a `LoadBalancer` Service following the active
mgr on port 8443. It pins an internal IP (`10.69.60.64`, via `lbipam.cilium.io/ips`) from
`internal-pool`, which Cilium's BGP control plane advertises to the MikroTik.

```bash
kubectl -n rook-ceph get svc rook-ceph-mgr-lb
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then browse to `https://<assigned-LB-IP>:8443` and log in as `admin`.

## Health check

The toolbox is enabled for quick status checks:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

A healthy fresh cluster reports `HEALTH_OK`, 6 OSDs `up`/`in`, and 3 mons in quorum.
