# Rook-Ceph Setup

In-cluster storage is [Rook](https://rook.io/)-managed [Ceph](https://ceph.com/):
**chart v1.20.2**, running **Ceph v20.2.2** (Tentacle). It backs cluster
PersistentVolumes with replicated block and shared-filesystem storage.

How the charts, versions, and values are chosen and kept reproducible is a
separate note: [Creating the Rook-Ceph Config](./creating-rook-ceph-config.md).
This note covers what the stack does day to day.

There is nothing to run by hand — Flux brings the whole stack up from the
manifests in `kubernetes/infrastructure/{controllers,configs}/rook-ceph/` once the
cluster is bootstrapped (see [Talos Cluster Setup](./talos-setup.md)). This note
explains what those manifests do and how to reach the dashboard.

## What runs where

Rook v1.20 splits into three Helm charts, wired across the two Flux stages so
nothing races its CRDs:

| HelmRelease | Chart | Stage | Role |
| --- | --- | --- | --- |
| `ceph-operator` | `rook-ceph` v1.20.2 | controllers | Operator + ceph-csi-operator subchart + all CRDs |
| `ceph-csi-drivers` | `ceph-csi-drivers` 1.0.4 | controllers | RBD/CephFS `Driver` CRs (`dependsOn` the operator) |
| `ceph-cluster` | `rook-ceph-cluster` v1.20.2 | configs | The `CephCluster` CR, pools, and StorageClasses |

`infra-controllers` runs with `wait: true`, so the operator and CSI drivers are
healthy before `infra-configs` reconciles the `CephCluster`.

> **New in v1.20:** the operator no longer deploys the CSI drivers itself. They
> are admin-managed via the ceph-csi-operator and configured by the separate
> `ceph-csi-drivers` chart (from the `https://ceph.github.io/ceph-csi-operator`
> repo). Its driver names must be `rook-ceph.{rbd,cephfs}.csi.ceph.com` to match
> the provisioner names the cluster chart bakes into the StorageClasses.

## Storage layout

- **OSDs** — one per node, on the raw 1 TB NVMe. `deviceFilter: ^nvme0n1` claims
  **only** that disk; the Talos OS install lives on the Samsung SSD 870 (selected
  by model in `talos/patch.yaml`), so Ceph never touches the OS disk. All six
  nodes (control-plane included, via a control-plane toleration) contribute an
  OSD → six OSDs.
- **Replication** — `size: 3` with `host` failure domain: every placement group
  lands on three distinct nodes, so a single node can be down without data loss.
- **StorageClasses**:
  - `ceph-block` — RBD (RWO), the **cluster-default** class.
  - `ceph-filesystem` — CephFS (RWX) for multi-node mounts.
- **No object store.** The RGW/S3 object store and `ceph-bucket` class are
  intentionally disabled (`cephObjectStores: []`) — nothing consumes buckets.
  Re-add a `cephObjectStores` entry in `cluster.yaml` if that changes.

The cluster values are a deliberately minimal, commented override set — only the
values we diverge on or pin against chart-default drift. Everything else is left
at the chart default.

## Fresh disks

Rook expects **empty** disks. A from-scratch bring-up gets them for free: the
Talos nuke (`talos/danger-reset-all-nodes.sh`) wipes `/dev/nvme0n1` on every
node, and a fresh Talos install leaves them clean, so there is no stale
OSD/LVM metadata for the OSD prepare jobs to trip over.

## Secrets

None in git. Ceph generates its own keyring and mon/OSD keys in-cluster; Rook
stores them as Kubernetes Secrets it creates itself. There is nothing to
SOPS-encrypt for Rook.

## Dashboard

The Ceph dashboard is enabled (HTTPS) and exposed on the LAN by
`configs/rook-ceph/dashboard-lb.yaml` — a `LoadBalancer` Service that follows the
active mgr (`mgr_role: active`) on port 8443. Cilium's BGP control plane assigns
it an IP from the `10.69.255.0/24` pool and advertises it to the MikroTik.

Find the IP and the auto-generated admin password:

```
kubectl -n rook-ceph get svc rook-ceph-mgr-lb
kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then browse to `https://<assigned-LB-IP>:8443` and log in as `admin`.

## Health check

The toolbox is enabled for quick status checks:

```
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

A healthy fresh cluster reports `HEALTH_OK`, 6 OSDs `up`/`in`, and 3 mons in
quorum.
