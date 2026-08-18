# Backups (Velero)

[Velero](https://velero.io/) backs up **PVC data** off-cluster to AWS S3. Everything else in
the cluster is already declaratively recoverable from this repo via Flux, so only the data
inside PersistentVolumes (Rook-Ceph) needs off-site protection. Versions are in
[Reference → Versions](../reference/versions.md).

There is **nothing to run by hand** day-to-day — Flux brings Velero up from
`kubernetes/infrastructure/platform/controllers/velero/`, and the `schedules` in its `HelmRelease` run
the backups. This page covers what it captures, the S3 cost design, and how to restore.

## What it captures

The schedule templates include only `pods`, `persistentvolumeclaims`, and
`persistentvolumes`, with `defaultVolumesToFsBackup: true`. Velero's **File System Backup**
(Kopia uploader, run by the `node-agent` DaemonSet) copies the actual volume *data* into S3;
the pod objects are just the handle FSB needs to locate a volume on its node. Deployments,
ConfigMaps, namespaces, and the rest are **not** backed up — they come back from Git via Flux.

So a recovery is two moves: Flux redeploys the workloads, and Velero restores their PVC data.

### The `minecraft` exception

The schedules carry `excludedNamespaces: [minecraft]`. Discovering volumes through running
pods cannot work for servers that sit at zero replicas most of the day, and file-system backup
does not quiesce a world it copies. Those worlds are backed up from inside their own pods
instead — see
[Decisions → Minecraft Scale-to-Zero](../decisions/minecraft-scale-to-zero.md#velero-cannot-back-up-a-sleeping-server).
The same blind spot would apply to any future workload that scales to zero.

## The S3 bucket

One bucket holds all off-cluster backups, created by Terraform (`terraform/backups.tf`) in the
`strudelan` account. It is deliberately generic (`homelab-backups-<suffix>`) and partitioned by
key prefix so consumers share it under their own prefix and their own scoped IAM user:

| Prefix | Written by | User |
| --- | --- | --- |
| `velero/` | Velero file-system backups | `homelab-velero` |
| `minecraft/` | In-pod restic backups of the worlds | `homelab-minecraft-backup` |
| `cnpg/<app>/` | CloudNativePG WAL archive + base backups | `homelab-cnpg-<app>` |

Postgres gets a user *per app* rather than one shared `cnpg` user, so a leaked database
credential reaches only that app's backups. The users are generated from a `for_each` over
`local.cnpg_apps`, so adding a database means adding one string.

The bucket blocks all public access and encrypts objects with SSE (AES256). The Velero IAM user
is scoped to the bucket's `velero/*` prefix only.

### Deletion resistance

The bucket is **versioned**, so a delete issued with the cluster's credentials writes a delete
marker rather than destroying data — a compromised cluster cannot erase backup history with what
it holds. Velero keeps `s3:DeleteObject` so its own TTL expiry behaves normally; what it does not
have is `s3:DeleteObjectVersion`, `s3:PutBucketVersioning`, or `s3:PutLifecycleConfiguration`.
Those three are also written as an explicit `Deny`, which no future widening of the `Allow`
statements can override.

Superseded versions are cleaned up by a lifecycle rule at **30 days** — long enough to notice a
delete that should not have happened, short enough that old versions do not accumulate cost
forever.

## Retention and cost

Three tiers, each a schedule with its own TTL:

| Tier | Schedule | Kept |
| --- | --- | --- |
| daily | `0 2 * * *` | 3 days |
| weekly | `0 3 * * 0` | 14 days |
| monthly | `0 4 1 * *` | 120 days |

Velero (via Kopia) deletes backups when their TTL expires and reclaims the space during repo
maintenance. **S3 itself never expires objects** on the `velero/` prefix — the Kopia repository
is a shared, deduplicated store, so letting S3 delete objects out from under it would corrupt
the repo.

### Why Glacier Instant Retrieval, transitioned at 14 days

Cost is optimized with a single lifecycle rule: transition `velero/` objects to **Glacier
Instant Retrieval (GIR)** after 14 days. The reasoning depends on how the Kopia repo behaves:

- A backup only *writes* new deduplicated blobs and reads a small, locally-cached index. It
  **never reads old data blobs** — those are read only during a restore. So the bulk of the
  data is genuinely cold.
- With deduplication, a blob only survives past the 14-day weekly window if the **120-day
  monthly** tier still references it. Transitioning at day 14 therefore only ever moves
  truly-cold, monthly-tier data into GIR, where it then sits ~106 days (day 14 → 120) —
  comfortably past **GIR's 90-day minimum storage duration**, so no early-deletion fee. Daily
  and weekly churn expires in Standard and never trips a fee.
- GIR is ~68% cheaper than Standard per GB but stays **synchronously readable**, so restores
  are still immediate and Velero's own maintenance never breaks. Steady-state retrieval cost is
  effectively zero; a full disaster restore reads GIR at roughly $0.03/GB — a few dollars for
  the whole dataset.

### Why the `cnpg/` prefix gets no transition

The Glacier rule is filtered to `velero/` on purpose. A Postgres WAL archive is a large
number of small objects, and Glacier Instant Retrieval bills a **128 KB minimum per
object** — transitioning WAL segments would cost *more* than leaving them in Standard, not
less. Retention there is Barman's job instead: each `ObjectStore` carries a
`retentionPolicy`, and obsolete backups are removed after the next backup completes.

The unfiltered `expire-noncurrent-versions` rule does apply to `cnpg/`, so the same 30-day
delete-marker recovery window protects Postgres backups too.

Deep Archive is deliberately *not* used: its objects need an asynchronous restore before they
can be read, which would break Kopia's maintenance on the shared repo, and the extra saving
over GIR is negligible at homelab scale. At these data sizes the real cost levers are Kopia's
deduplication and the retention TTLs; the GIR rule is structured so it can only help, never add
fees.

## Credentials

The Velero IAM access key is created by Terraform and surfaced as two `sensitive` outputs
(`velero_access_key_id` / `velero_secret_access_key`). They are copied by hand into
`platform/controllers/velero/secret.sops.yaml` (a `cloud` credentials file, SOPS-encrypted to the admin
+ cluster keys); Flux decrypts it in-cluster. See [Secrets](./secrets.md). Terraform never
writes secrets into the cluster.

First-time bring-up (after `terraform apply`):

```bash
cd terraform
BUCKET=$(terraform output -raw backups_bucket)
terraform output -raw velero_access_key_id
terraform output -raw velero_secret_access_key
```

Put `$BUCKET` into the `backupStorageLocation.bucket` field of
`platform/controllers/velero/helm-release.yaml`, put the keys into the secret
(`sops platform/controllers/velero/secret.sops.yaml`), commit, then
`flux reconcile kustomization infra-controllers --with-source`.

## Health check

```bash
kubectl -n velero get pods                 # velero + one node-agent per node
velero backup-location get                 # default → Available
velero schedule get                        # daily / weekly / monthly
velero backup get                          # completed backups
```

## Restore

List a backup's contents, then restore just the PVC data (Flux recreates the workloads):

```bash
velero backup describe <backup> --details
velero restore create --from-backup <backup> \
  --include-resources persistentvolumeclaims,persistentvolumes
```

Restore into a scratch namespace first (`--namespace-mappings old:new`) if you want to verify
data before touching the live namespace.

## Deferred

- **CSI Snapshot Data Movement** would give snapshot-consistent, pod-independent PVC backups
  (no need to include `pods`), but needs the external `snapshot-controller`, a Rook
  `VolumeSnapshotClass`, and Velero's `EnableCSI` feature. Left out to keep this lean.
- **Object Lock** (a retention period S3 itself enforces, binding even on the bucket owner) is
  not enabled. Versioning plus the scoped IAM `Deny` already covers the realistic threat — a
  compromised cluster credential — without the operational cost of objects that genuinely cannot
  be removed early.
