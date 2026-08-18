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
| Shlink | `16e.link` | HTTPS via a Cilium `Ingress`; short-link API and redirects; Postgres backing store |
| Shlink admin UI | `admin.16e.link` | Its own `Ingress`, IP, and certificate — internal-only permanently |
| Minecraft | `*.mc.lilstrudel.io` | Raw TCP `25565` `LoadBalancer` fronting a fleet of servers — see [Minecraft](./minecraft.md) |
| Factorio | `factorio.lilstrudel.io` | Raw UDP `34197` `LoadBalancer`, no ingress, no TLS |

Every hostname is a pinned IP in `local.services` (`terraform/main.tf`), which is both the
DNS source of truth and the allocation record.

## Databases

Vaultwarden and Shlink each own a CloudNativePG `Cluster` in their own namespace, declared
beside the Deployment they back. Neither keeps application state on a PVC any more —
Shlink has no volume at all, and Vaultwarden's remaining PVC holds only attachments and
icons. Credentials come from the CNPG-generated `<cluster>-app` Secret via `secretKeyRef`,
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
| `dashy`, `vaultwarden`, `minecraft`, `factorio` | `restricted` | — |
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

## The Shlink admin UI is internal-only

`admin.16e.link` ships an SPA that hands a working Shlink admin API key to any browser
that loads it. It is deliberately built as its own `Ingress`, IP, and certificate so that
publishing the short-link host can never expose it. See
[Decisions → Service Networking](../decisions/service-networking.md#the-shlink-admin-ui-is-its-own-everything).

## Secrets

App credentials are SOPS-encrypted `*.sops.yaml` Secrets committed beside their manifests
and decrypted in-cluster by the owning Flux Kustomization — see [Secrets](./secrets.md).
