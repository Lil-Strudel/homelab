# Applications

The user-facing workloads under `kubernetes/apps/`, and the constraints each one
carries. How to add another is [Adding a Service](./adding-a-service.md); why service IPs
and exposure work the way they do is
[Decisions → Service Networking](../decisions/service-networking.md).

Most of them live in `apps/main/` and reconcile as one Flux Kustomization. Minecraft is the
exception: it sits in `apps/minecraft/` under its own Kustomization, because a cold modpack
download takes longer than any timeout the shared one should carry.

| App | Hostname | Shape |
| --- | --- | --- |
| Dashy | `dashy.lilstrudel.io` | HTTPS via a Cilium `Ingress`; the lab's landing page — see [Dashboard](./dashboard.md) |
| Vaultwarden | `vault.lilstrudel.io` | HTTPS via a Cilium `Ingress` + `letsencrypt-prod` cert; Postgres backing store |
| Immich | `immich.lilstrudel.io` | HTTPS via a Cilium `Ingress`; photo library on 100Gi of `ceph-block`, Postgres backing store |
| Shlink | `16e.link` | HTTPS via a Cilium `Ingress`; short-link API and redirects; Postgres backing store |
| Shlink admin UI | `admin.16e.link` | Its own `Ingress`, IP, and certificate — internal-only permanently |
| Minecraft | `*.mc.lilstrudel.io` | Raw TCP `25565` `LoadBalancer` fronting a fleet of servers — see [Minecraft](./minecraft.md) |
| Factorio | `factorio.lilstrudel.io` | Raw UDP `34197` `LoadBalancer`, no ingress, no TLS |
| RustDesk | `rustdesk.lilstrudel.io` | Raw TCP `21115`–`21117` + UDP `21116` `LoadBalancer`, no ingress, no TLS |

Every hostname is a pinned IP in `local.services` (`terraform/main.tf`), which is both the
DNS source of truth and the allocation record.

## Databases

Vaultwarden, Shlink, and Immich each own a CloudNativePG `Cluster` in their own namespace,
declared beside the Deployment they back. Only Immich keeps bulk state on a PVC — Shlink has
no volume at all, and Vaultwarden's remaining PVC holds only attachments and icons.
Credentials come from the CNPG-generated `<cluster>-app` Secret via `secretKeyRef`,
so no database password is committed. See [Postgres](./postgres.md).

### Vaultwarden runs the Debian image, not Alpine

`vaultwarden/server:1.37.0`, deliberately without the `-alpine` suffix. On Postgres the
Alpine build crashes at startup with `SIGSEGV`/`SIGBUS` (exit 139/135) before Rocket
finishes launching — non-deterministically, so it sometimes survives one start and dies on
the next. The database itself is fine: schema migrations complete, and the same
`DATABASE_URL` works on the Debian image with zero restarts. `RUST_MIN_STACK=8388608`
makes it *less* frequent but does not fix it, which is what points at musl rather than
configuration.

The Alpine image is fine on SQLite; this only shows up against Postgres.

### Immich needs VectorChord, which the standard Postgres image does not carry

Immich stores CLIP and face-recognition embeddings in Postgres and checks the extension at
startup — outside `vchord >= 0.3 < 2` it refuses to run. Immich ships its own Postgres
image for this, but that image is not CloudNativePG-compatible, so `immich-pg` stays on the
same `postgresql-standard-trixie` operand as every other cluster and mounts VectorChord as
an image volume instead. The mechanics are in [Postgres](./postgres.md#shape).

The `immich` role is granted `SUPERUSER`. That is the configuration Immich documents and
expects: it creates the extension itself, and on a VectorChord bump it runs
`ALTER EXTENSION vchord UPDATE` and reindexes `face_index` and `clip_index` without
intervention. On a large library that first start after a bump is slow, not instant. The
alternative — an unprivileged role with the extensions pre-created — turns every bump into
a manual `psql` session, which upstream marks advanced-users-only.

Immich's own database backup stays off. It shells out to `pg_dumpall` and would write dumps
into the photo volume, duplicating what barman-cloud already ships to S3.

### Immich splits one volume three ways

`immich-library` is a single 100Gi RWO claim mounted at `/data`; Immich lays out `upload/`,
`library/`, `thumbs/`, `encoded-video/`, `profile/`, and `backups/` beneath it and writes a
`.immich` marker into each at startup to prove the mount is present. Because the volume is
RWO the server Deployment uses `strategy: Recreate`, and because it is large it sets
`fsGroupChangePolicy: OnRootMismatch` — the default would recursively chown the whole
library on every pod start.

The machine-learning pod mounts a separate `immich-model-cache` claim at `/cache`, labelled
`velero.io/exclude-from-backup` since the model weights re-download from Hugging Face. That
download is also the one piece of app egress that has to be allowed by FQDN, and each label
depth is listed separately because Cilium's `*` never crosses a dot.

Valkey backs the job queue on an `emptyDir`. A restart drops queued jobs; the "missing
thumbnails" and "missing ML" jobs rebuild the backlog from the database.

## The hardening baseline

Every app pod runs the same posture, and a new one is expected to match it:

- non-root (`runAsNonRoot`, explicit UID/GID, `fsGroup` where a volume is written),
- `allowPrivilegeEscalation: false` and **all** capabilities dropped,
- `seccompProfile: RuntimeDefault`,
- `automountServiceAccountToken: false`.

The last one has exactly one exception, and it is worth knowing why: **mc-router** scales
Minecraft servers up and down, so it holds a token — bound to a namespaced `Role` that can
read Services and patch StatefulSet replicas, and nothing else. Every other app pod here has
no reason to reach the API server and no credential to do it with.

Namespaces enforce Pod Security Admission `restricted`, with one exception:

| Namespace | Enforce | Why |
| --- | --- | --- |
| `dashy`, `vaultwarden`, `immich`, `minecraft`, `factorio`, `rustdesk` | `restricted` | — |
| `shlink` | `baseline` | The `shlink-web-client` nginx entrypoint writes `servers.json` into the image's html directory, which a non-root UID cannot create. `warn`/`audit` stay at `restricted` so the gap stays visible. |

Each namespace also carries a **default-deny `CiliumNetworkPolicy`** covering ingress and
egress, selecting every endpoint in the namespace. What each app is allowed is then
written back in explicitly: DNS to `kube-dns` for all of them, the app's own listening
port from the entities that legitimately reach it, and per-app egress by FQDN where a
workload genuinely needs the internet — each Minecraft server reaches only the host it
downloads its own server jar or modpack from, plus Mojang for player authentication, and
Factorio talks to `*.factorio.com`. Dashy needs no internet at all — its egress is DNS plus
the handful of in-cluster endpoints it status-checks, listed in
[Dashboard](./dashboard.md#status-checks).

## RustDesk is two binaries around one volume

The OSS RustDesk server is `hbbs`, the ID/rendezvous server, and `hbbr`, the relay. They
run as two containers in one pod sharing a single `ceph-block` claim mounted at `/root`,
which is the working directory both binaries read and write. `hbbs` keeps three things
there: `id_ed25519` and `id_ed25519.pub`, generated on first start, and `db_v2.sqlite3`,
the registered-peer table. Because the claim is RWO the Deployment uses
`strategy: Recreate`, and because the image is `FROM scratch` — no `/root` in the layers at
all — the directory comes into existence as the mount and is owned by `fsGroup: 1000`,
which is what lets the pod satisfy `restricted` while still writing its own keypair.

Neither binary is given a `-k` flag. `hbbs` already defaults to loading or generating the
key pair, and `hbbr` deliberately defaults to an empty key: turning relay validation on
would have both containers racing to create the pair on an empty volume, since `hbbr`
waits only 300 ms for the file to appear. The relay carries nothing but ciphertext —
sessions are encrypted end to end between peers — and is reachable only from the Home VLAN
and the Home VPN, so the validation it would add is worth less than the silent
key-mismatch failure it would risk.

`hbbs` is also not given `-r`. That flag exists to tell clients where the relay lives when
it differs from the ID server; here both answer on `10.69.65.26` and `hbbr` is on its
standard port `21117`, so clients derive it, and the address is written down once instead
of twice.

The web-client listeners (`21118` on `hbbs`, `21119` on `hbbr`) are not exposed. They trust
the `X-Real-IP` and `X-Forwarded-For` headers of incoming WebSocket connections without
validating them, so anyone able to reach them can forge a source address; the desktop and
mobile clients need neither.

### Pointing a client at it

Menu [ ⋮ ] → Network → unlock, then **ID Server** `rustdesk.lilstrudel.io` and **Key** the
server's public key. Relay Server and API Server stay blank. The key is the `Key:` line
`hbbs` logs on every start:

```
kubectl -n rustdesk logs deploy/rustdesk -c hbbs | grep '^.*Key:'
```

The log is the only way to read it — the image has no shell, so `kubectl exec ... cat
/root/id_ed25519.pub` will not run.

## The Shlink admin UI is internal-only

`admin.16e.link` ships an SPA that hands a working Shlink admin API key to any browser
that loads it. It is deliberately built as its own `Ingress`, IP, and certificate so that
publishing the short-link host can never expose it. See
[Decisions → Service Networking](../decisions/service-networking.md#the-shlink-admin-ui-is-its-own-everything).

## Secrets

App credentials are SOPS-encrypted `*.sops.yaml` Secrets committed beside their manifests
and decrypted in-cluster by the owning Flux Kustomization — see [Secrets](./secrets.md).
