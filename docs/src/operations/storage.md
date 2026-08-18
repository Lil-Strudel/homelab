# Storage (Rook-Ceph)

In-cluster storage is [Rook](https://rook.io/)-managed [Ceph](https://ceph.com/), serving
all three of its datastore types: replicated block, shared filesystem, and S3 object
storage. Versions are in [Reference → Versions](../reference/versions.md); the storage design
(OSD layout, replication, StorageClasses) is in
[Architecture → Storage](../architecture.md#storage); the value choices are in
[Decisions → Rook-Ceph Values](../decisions/rook-ceph.md).

There is **nothing to run by hand** — Flux brings the whole stack up from
`kubernetes/infrastructure/core/{controllers,configs}/rook-ceph/` once the cluster is
bootstrapped. This page is day-2: what runs, how to reach the dashboard, and how to
check health.

## What runs where

Rook v1.20 splits into three Helm charts, wired across the two core stages so nothing
races its CRDs:

| HelmRelease | Chart | Stage | Role |
| --- | --- | --- | --- |
| `ceph-operator` | `rook-ceph` | core-controllers | Operator + ceph-csi-operator subchart + all CRDs |
| `ceph-csi-drivers` | `ceph-csi-drivers` | core-controllers | RBD/CephFS `Driver` CRs (`dependsOn` the operator) |
| `ceph-cluster` | `rook-ceph-cluster` | core-configs | The `CephCluster` CR, pools, StorageClasses, and object store |

`core-controllers` runs with `wait: true`, so the operator and CSI drivers are healthy
before `core-configs` reconciles the `CephCluster`.

## What you can claim

| Want | Use | Backed by |
| --- | --- | --- |
| An RWO volume (the default) | StorageClass `ceph-block` | RBD pool, 3× replicated |
| An RWX volume shared by many pods | StorageClass `ceph-filesystem` | CephFS, 3× replicated |
| An S3 bucket | An `ObjectBucketClaim` on StorageClass `ceph-bucket` | RGW, **erasure-coded 2+1** |

`ceph-block` is the cluster default, so a PVC with no `storageClassName` lands there.

### Claiming a bucket

An `ObjectBucketClaim` provisions a bucket and writes its coordinates into **the OBC's own
namespace** — a ConfigMap and a Secret, both named after the claim:

```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: myapp-bucket
  namespace: myapp
spec:
  generateBucketName: myapp
  storageClassName: ceph-bucket
```

The ConfigMap carries `BUCKET_NAME`, `BUCKET_HOST`, and `BUCKET_PORT`; the Secret carries
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Consume both with `envFrom` rather than
hardcoding anything — the bucket name is generated and the credentials are per-claim, so
nothing needs to be committed. Loki does exactly this; see
[Observability](./observability.md#logs).

**An OBC belongs no earlier than `platform/controllers`.** It needs the `ceph-bucket`
StorageClass, which `core-configs` creates — claiming one from an earlier stage deadlocks.
See [Decisions → Infrastructure Layering](../decisions/infrastructure-layering.md).

The gateway is in-cluster only, at `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc` over
plain HTTP on port 80. There is no Ingress and no LAN endpoint, because nothing outside the
cluster uses it. Inspect buckets from the toolbox:

```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- radosgw-admin bucket list
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph df
```

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
Cilium `Ingress` in `core/configs/rook-ceph/dashboard-ingress.yaml`. The Ingress pins
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

The object store adds several pools of its own (metadata, data, index, control) on the same
six OSDs. The PG autoscaler sizes them, but a `TOO_MANY_PGS` or `POOL_TOO_FEW_PGS` warning
in `ceph status` after a pool count change is worth reading rather than ignoring.
