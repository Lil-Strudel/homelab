# Postgres (CloudNativePG)

Relational storage is [CloudNativePG](https://cloudnative-pg.io/), one Postgres cluster per
app. Versions are in [Reference → Versions](../reference/versions.md); the operator and the
backup plugin install from `kubernetes/infrastructure/platform/controllers/cnpg/`.

There is **nothing to run by hand** — Flux brings up the operator, and each app's `Cluster`
comes up beside the app it serves. This page is day-2: the shape, the backups, and how to
recover.

## One cluster per app, not one shared cluster

Each app owns a `Cluster` in **its own namespace**, sitting in `apps/main/<app>/` next to
the Deployment it backs. That is a deliberate choice over a single shared instance, and the
deciding constraint is credentials:

- CloudNativePG generates the application role's Secret (`<cluster>-app`) in the cluster's
  own namespace, and **cross-namespace Secret references are not supported** — not for
  `managed.roles[].passwordSecret`, and not for an app reading its own password. A shared
  cluster therefore means every database password is committed **twice**, in two SOPS files
  that have to stay in sync.
- `Database` CRs and role definitions must live beside the `Cluster` too, so a shared
  cluster would put each app's schema config in a namespace that app does not own.
- Point-in-time recovery restores a **whole cluster**. Sharing one means rolling Vaultwarden
  back an hour also rolls back Shlink.

Postgres' own tenant isolation would have been adequate — separate roles and databases hold
up fine, and `enableSuperuserAccess` defaults to `false` so there is no cluster-wide
credential to leak. The argument against sharing is the plumbing, not the security model.

The cost is small: an idle instance is ~100-200 MiB, so two 2-instance clusters is four
pods.

## Shape

| | |
| --- | --- |
| Instances | 2 — a primary and one streaming replica, on different nodes via `enablePodAntiAffinity` |
| Image | `ClusterImageCatalog` `postgresql-standard-trixie`, major 18, digest-pinned |
| Storage | `ceph-block` (RWO, 3× replicated), no separate `walStorage` |
| Backups | barman-cloud plugin → AWS S3 under `cnpg/<app>/` |

**Two instances, not three.** The SLA here is low and recovery matters more than uptime; a
single replica is what makes a Talos node roll a switchover rather than an outage. If both
were lost, the S3 backup is the recovery path.

**No `walStorage`.** CNPG's guidance is that *"in most cases, having `pg_wal` on the same
volume where `PGDATA` resides is fine"* — the split is for high-write workloads. It also
cannot be undone once set, so the simple layout is the right default.

**`ceph-block` at 3×, not a replica-1 pool.** CNPG's storage docs suggest reducing block
replicas to one, but that guidance is conditional on no single point of failure existing at
the storage level, and a stock Ceph pool cannot meet it: an RBD image is striped across
every OSD in the pool, so at `size: 1` a single OSD loss punches holes in *every* volume at
once — including both Postgres instances. Node rolls are routine here, so that is a
correlated failure, not a rare one. The advice fits storage with per-node locality
(Longhorn), which Ceph does not have.

## Connecting

CloudNativePG generates `<cluster>-app` in the app's namespace, holding `username`,
`password`, `dbname`, `host`, `port`, and a ready-made `uri`. Nothing is committed — read
it with `secretKeyRef`:

```yaml
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: vaultwarden-pg-app
      key: uri
```

Apps that want the parts separately (Shlink) take `host`, `dbname`, `username`, and
`password` as individual keys.

Traffic goes to the `<cluster>-rw` Service; each namespace's `CiliumNetworkPolicy` opens
`5432` from the app and between instances, `8000`/`9187` from `cnpg-system` and the kubelet,
and egress to S3 for the backup sidecar.

## Backups

The in-tree `barmanObjectStore` is deprecated; backups go through the **barman-cloud CNPG-I
plugin**, which needs cert-manager for its mTLS certificates. Each app has an `ObjectStore`
CR (namespace-scoped, so it lives with the cluster) pointing at `cnpg/<app>/` in the shared
backup bucket, with its own scoped IAM user — see [Backups](./backups.md).

A `ScheduledBackup` runs daily. Note the schedule is a **six-field Go cron spec that leads
with seconds**, not the Unix five-field form:

```yaml
schedule: "0 0 3 * * *"   # 03:00 daily
```

Retention lives on the `ObjectStore` (`retentionPolicy: 30d`), not the `Cluster`. Obsolete
backups are removed *after the next backup completes*, so retention only advances while
backups keep running.

**Velero deliberately does not back these volumes up.** Each `Cluster` carries
`inheritedMetadata.labels."velero.io/exclude-from-backup": "true"`, which CNPG propagates to
its pods and PVCs. A file-system copy of a live `PGDATA` is not a valid backup — no WAL
consistency, no PITR — and storing one would also duplicate the data in S3. See
[Backups](./backups.md).

## Monitoring

Both the operator and every instance are scraped by VictoriaMetrics. Each is a
`VMPodScrape` rather than a `VMServiceScrape`: the operator chart publishes only its webhook
Service, and CNPG's generated `-rw`/`-ro`/`-r` Services expose 5432 alone, so in both cases
the metrics port exists on the pod and nowhere else.

| Scrape | Target | Lives in |
| --- | --- | --- |
| `cloudnative-pg` | Operator, port 8080 | `platform/configs/cnpg/` |
| `<app>-pg` | Instances, port 9187 | `apps/main/<app>/` |

The instance scrapes sit with their apps because they target namespaces `apps` creates —
a scrape in `platform/configs/` would reconcile before that namespace exists and fail the
whole stage. See [Adding a Service](./adding-a-service.md).

vmagent scrapes from the `victoria-metrics` namespace, so each app's
`CiliumNetworkPolicy` opens 9187 to it explicitly; the same-namespace rule that covers the
instance-to-instance traffic does not reach across.

There is no alerting yet — `vmalert` and Alertmanager are both disabled, so these metrics
are collected and graphable but nothing pages on them.

## Health check

```bash
kubectl get cluster -A
kubectl -n <app> get pods -l cnpg.io/cluster=<app>-pg
kubectl -n <app> get backup
```

A healthy cluster reports `2/2` instances with one primary. To open a shell:

```bash
kubectl -n <app> exec -it <app>-pg-1 -c postgres -- psql
```

## Restore

Recovery bootstraps a **new** cluster from the object store — you do not restore in place.
Point a fresh `Cluster` at the backup with `bootstrap.recovery`, referencing the same
`ObjectStore` through `externalClusters`:

```yaml
spec:
  bootstrap:
    recovery:
      source: <app>-backup
      # recoveryTarget:
      #   targetTime: "2026-08-17 03:00:00.00000+00"   # omit to recover to the latest WAL
  externalClusters:
    - name: <app>-backup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: <app>-backup
          serverName: <app>-pg
```

Bring it up under a different `metadata.name`, verify the data, then repoint the app's
Secret references at the new cluster.
