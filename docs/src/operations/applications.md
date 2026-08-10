# Applications

The user-facing workloads under `kubernetes/apps/main/`, and the constraints each one
carries. How to add another is [Adding a Service](./adding-a-service.md); why service IPs
and exposure work the way they do is
[Decisions → Service Networking](../decisions/service-networking.md).

| App | Hostname | Shape |
| --- | --- | --- |
| Vaultwarden | `vault.lilstrudel.io` | HTTPS via a Cilium `Ingress` + `letsencrypt-prod` cert |
| Shlink | `16e.link` | HTTPS via a Cilium `Ingress`; short-link API and redirects |
| Shlink admin UI | `admin.16e.link` | Its own `Ingress`, IP, and certificate — internal-only permanently |
| Minecraft | `minecraft.lilstrudel.io` | Raw TCP `25565` `LoadBalancer`, no ingress, no TLS |
| Factorio | `factorio.lilstrudel.io` | Raw UDP `34197` `LoadBalancer`, no ingress, no TLS |

Every hostname is a pinned IP in `local.services` (`terraform/main.tf`), which is both the
DNS source of truth and the allocation record.

## The hardening baseline

Every app pod runs the same posture, and a new one is expected to match it:

- non-root (`runAsNonRoot`, explicit UID/GID, `fsGroup` where a volume is written),
- `allowPrivilegeEscalation: false` and **all** capabilities dropped,
- `seccompProfile: RuntimeDefault`,
- `automountServiceAccountToken: false` — none of them talk to the Kubernetes API.

Namespaces enforce Pod Security Admission `restricted`, with one exception:

| Namespace | Enforce | Why |
| --- | --- | --- |
| `vaultwarden`, `minecraft`, `factorio` | `restricted` | — |
| `shlink` | `baseline` | The `shlink-web-client` nginx entrypoint writes `servers.json` into the image's html directory, which a non-root UID cannot create. `warn`/`audit` stay at `restricted` so the gap stays visible. |

Each namespace also carries a **default-deny `CiliumNetworkPolicy`** covering ingress and
egress, selecting every endpoint in the namespace. What each app is allowed is then
written back in explicitly: DNS to `kube-dns` for all of them, the app's own listening
port from the entities that legitimately reach it, and per-app egress by FQDN where a
workload genuinely needs the internet — Minecraft fetches the Paper jar and authenticates
players against Mojang, Factorio talks to `*.factorio.com`.

## Minecraft: plugins and datapacks

The server keeps its world on a `ceph-block` RWO PVC and its plugins and datapacks on
two separate `ceph-filesystem` **RWX** PVCs, mounted at `/plugins` and `/datapacks`. RWX
is what lets a helper pod add or remove a jar while the server is running — including
while it is crash-looping on a bad plugin, when `kubectl cp` into the pod is not an
option.

> **Put a `.zip` on the datapacks PVC before setting `DATAPACKS`.**
>
> The `DATAPACKS` environment variable is unset. Pointing it at a directory that holds no
> `.zip` **crashes the server on startup**: upstream's init script runs
> `cp "$DATAPACKS"/*.zip` unguarded, the glob fails to expand, and init aborts before the
> server ever starts. The mount is present regardless, so the ordering is:
>
> 1. write at least one `.zip` onto the `minecraft-datapacks` PVC,
> 2. *then* set `DATAPACKS=/datapacks` on the container and commit.
>
> Removing the last `.zip` while the variable is set puts the server back into the same
> crash loop, so unset it in the same change that empties the PVC.

Plugins have no such requirement — an empty `/plugins` is fine.

## The Shlink admin UI is internal-only

`admin.16e.link` ships an SPA that hands a working Shlink admin API key to any browser
that loads it. It is deliberately built as its own `Ingress`, IP, and certificate so that
publishing the short-link host can never expose it. See
[Decisions → Service Networking](../decisions/service-networking.md#the-shlink-admin-ui-is-its-own-everything).

## Secrets

App credentials are SOPS-encrypted `*.sops.yaml` Secrets committed beside their manifests
and decrypted in-cluster by the owning Flux Kustomization — see [Secrets](./secrets.md).
