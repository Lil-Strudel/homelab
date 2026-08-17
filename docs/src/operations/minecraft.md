# Minecraft

A fleet of Minecraft servers behind one address. Servers sit at **zero replicas** until a
player connects, wake on demand, and go back to sleep ten minutes after the last one leaves.
Versions are in [Reference → Versions](../reference/versions.md); why it is built this way is
[Decisions → Minecraft Scale-to-Zero](../decisions/minecraft-scale-to-zero.md).

There is **nothing to run by hand** — Flux brings the whole thing up from
`kubernetes/apps/minecraft/`. This page is day-2: what runs, how to add a server or a player,
and how to get a world back.

## What runs

| Component | Shape | Role |
| --- | --- | --- |
| mc-router | `Deployment`, 2 replicas | The only entry point: `10.69.65.30:25565`. Routes on the handshake hostname and scales servers 0↔1 |
| `survival-1` | `StatefulSet` | Paper survival. The **default route** — catches `mc.lilstrudel.io` and anything unmatched |
| `survival-2` | `StatefulSet` | Paper survival at `survival-2.mc.lilstrudel.io` |
| `cobblemon` | `StatefulSet` | The official Cobblemon Fabric modpack at `cobblemon.mc.lilstrudel.io` |

Every server pod carries three containers: the server itself, an `mc-monitor` sidecar
exporting player counts to VictoriaMetrics, and an `mc-backup` sidecar pushing restic
snapshots to S3.

DNS is a single **match-subdomain** record: `mc.lilstrudel.io` and every name beneath it
resolve to `10.69.65.30`. That is what makes a new server need no DNS change at all.

## Sleep and wake

mc-router watches Services in the namespace for `mc-router.itzg.me/externalServerName` and
maps each hostname to its backend. When a player connects to a server whose `StatefulSet` is
at zero, it patches replicas to 1 and holds the connection until the server answers; after
`--auto-scale-down-after` with no connections, it patches back to 0.

A **server-list ping does not wake anything** — the client just sees the asleep MOTD. That is
deliberate: every launcher pings every server on its list, and waking on pings would keep
everything running permanently.

Two consequences worth knowing:

- **The first connect to a cold server is slow**, and slowest of all for Cobblemon, whose
  measured first boot on an empty volume is around 14 minutes — scheduling, then the modpack
  download, then world gen. Later wakes are about a minute. Each Service carries
  `mc-router.itzg.me/autoScaleWaitTimeout` sized for its own cold start; the default is 60
  seconds, which a modpack will never meet.
- **Servers see mc-router's pod IP, not the player's.** Fine while this is LAN-only behind a
  whitelist; it would need the PROXY protocol before publishing.

## Fleet capacity

The three workers have roughly 15Gi allocatable each and carry about 10Gi of baseline
requests, so only about 5Gi per node is free for Minecraft. A survival pod requests ~2.7Gi and
Cobblemon requests ~5.2Gi, which means:

- **Cobblemon fits only on a worker that no survival server is currently awake on.** If every
  node is occupied it stays `Pending` and the waking player just waits — the symptom is a pod
  in `Pending` with `Insufficient memory`, not an error anywhere in mc-router.
- Two survival servers plus Cobblemon awake at once does not fit today.

This is the practical ceiling on how many servers can be *awake* together; it does not limit
how many can exist, since sleeping servers request nothing. Growing the fleet past this means
either more node memory or smaller heaps.

## Adding a server

Copy an existing overlay under `kubernetes/apps/minecraft/servers/`, change five things, and
add one line. No IP to claim, no DNS record, no Terraform.

1. `kustomization.yaml` — the `namePrefix` and the `mc.lilstrudel.io/server` label.
2. `statefulset.yaml` — `TYPE`/`VERSION` (or the `MODRINTH_*` set), `MEMORY`, resources, MOTD,
   and the server's own `RESTIC_REPOSITORY` path.
3. `service.yaml` — `mc-router.itzg.me/externalServerName`, and a `autoScaleWaitTimeout` that
   matches how slow a cold boot really is.
4. `network-policy.yaml` — the hosts this server downloads from, and nothing else.
5. `pvc.yaml`, only if the default disk is the wrong size.
6. Add the directory to `resources:` in `kubernetes/apps/minecraft/kustomization.yaml`.

Two rules the base enforces that a new overlay must not undo:

> **Never set `spec.replicas`.** mc-router owns that field. Declaring it hands ownership to
> Flux, which will revert every wake and disconnect players mid-session.
>
> **Leave `kustomize.toolkit.fluxcd.io/prune: disabled` on the PVC.** `ceph-block` reclaims on
> delete, so without it a careless `git rm` destroys the world and its RBD image.

Renovate needs to know about any new pinned game version — a Paper `VERSION` is covered by the
existing `papermc` manager's path glob only if the directory is named `survival-*`; anything
else needs its own `customManagers` entry. See
[Adding a Service](./adding-a-service.md#2-confirm-renovate-coverage).

## Adding a player

One line, one file. `kubernetes/apps/minecraft/config/common.env` holds the roster shared by
every server:

```
WHITELIST=<uuid>,<uuid>
OPS=<uuid>
```

Append the new UUID and commit. Use **UUIDs, not usernames** — a username list makes the server
resolve names against Mojang on every start, which the egress policy does not allow.

The file is a `configMapGenerator` input, so its content hash is part of every server's pod
spec: changing it rolls all three servers. That is required, not incidental — the image only
writes `whitelist.json` at startup, so a restart is the only way the change takes effect.

## Backups

Velero does **not** back these worlds up, and is explicitly excluded from the namespace — see
[Decisions → Minecraft Scale-to-Zero](../decisions/minecraft-scale-to-zero.md#velero-cannot-back-up-a-sleeping-server).

Instead each pod runs an `mc-backup` sidecar that quiesces the world over RCON
(`save-off` → `save-all` → snapshot → `save-on`) and pushes to a per-server restic repository
under the `minecraft/` prefix of the backups bucket. Each server gets its own repository, so two
servers waking together never contend for a lock. It snapshots two minutes into a session and
hourly after that, and only while players are online — an awake but empty server re-uploads
nothing.

Because it lives in the pod, it runs exactly when the world is changing. That has one edge worth
knowing: **the sidecar does not snapshot on shutdown.** When mc-router scales a server to zero it
sends `SIGTERM`, and mc-backup's only exit handler is the RCON `save-on` that unwinds a
quiesce — so play between the last hourly snapshot and sleep is not captured. Shortening
`BACKUP_INTERVAL` narrows that window; restic deduplicates, so frequent snapshots of a mostly
unchanged world are cheap.

The repository password is in the `minecraft-backup` SOPS secret. **Keep a copy in the password
manager** — restic snapshots are unreadable without it, and the cluster is not a safe sole
custodian of the key to its own backups.

### Restoring a world

```bash
kubectl -n minecraft scale statefulset survival-1-mc --replicas=0
```

Then run a throwaway pod from the `itzg/mc-backup` image with the same PVC and secret attached,
and restore into it:

```bash
restic snapshots
restic restore latest --target /data
```

Scale back to 1 and reconnect. mc-router will take over the replica count again on the next
player connect.

> **Prove this once before you rely on it.** An untested restore is not a backup, and the
> failure modes here (wrong repository path, missing password, an IAM policy that allows writes
> but not reads) all look like success until the day you need the data.

## Where to look when something is wrong

| Symptom | Look at |
| --- | --- |
| Server never wakes | mc-router logs — RBAC on `statefulsets/scale`, or a Service whose name does not match the StatefulSet's `serviceName` |
| Client times out on first connect | `autoScaleWaitTimeout` is shorter than the cold start |
| A server boots but fails to download | `hubble observe --namespace minecraft --verdict DROPPED` — a missing FQDN in that server's policy |
| Backups silently absent | The sidecar's logs; `PAUSE_IF_NO_PLAYERS` means an empty server is expected to skip |
| Players kicked after a Flux sync | `spec.replicas` has crept back into a StatefulSet manifest |

Logs need no setup — Alloy ships every pod's output to Loki, and the **Minecraft** Grafana
dashboard carries player counts, awake/asleep state, resource use, and a log panel.
