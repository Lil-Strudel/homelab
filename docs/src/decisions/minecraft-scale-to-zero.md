# Minecraft Scale-to-Zero

Running several Minecraft servers on six small nodes only works if the idle ones cost nothing.
The day-to-day runbook is [Operations → Minecraft](../operations/minecraft.md); this note is
the reasoning behind the three choices that shape it.

## mc-router owns the replica count, not the image

The `itzg/minecraft-server` image ships two idle mechanisms, and neither reclaims what matters:

- `ENABLE_AUTOPAUSE` `SIGSTOP`s the JVM. CPU drops to nothing, but **the heap is still
  resident** — three paused servers hold exactly as much RAM as three busy ones. On a fleet
  that is the whole problem, not a solution to it.
- `ENABLE_AUTOSTOP` stops the server, the container exits, and the controller restarts it.

Both leave the pod scheduled. Only changing `replicas` to 0 gives the memory back, and the
thing that knows whether anyone is connected is the proxy every connection passes through. So
mc-router does both halves — `--auto-scale-up` on connect, `--auto-scale-down` after an idle
period — and the image's own pause and stop features stay off.

This also makes the fleet's cost model legible: **capacity is what is awake**, and
`kube_statefulset_status_replicas` is the whole answer.

## `spec.replicas` is absent from every StatefulSet

Flux reconciles with server-side apply, which claims ownership of every field a manifest
declares. Declare `replicas` and two controllers own it: mc-router patches it to 1 when a
player knocks, and Flux sets it back on the next reconcile — disconnecting whoever just
joined, on an interval, in a way that looks like a network fault.

Omitting the field entirely leaves it outside Flux's field set, so mc-router's patches stand.
The cost is small and worth stating: on **create**, the API server defaults `replicas` to 1, so
a brand-new server boots once and falls asleep ten minutes later.

The trap is adding the field and later removing it. Removing a field you own does not release
it — it deletes it, resetting the value once. So it never goes in.

## Velero cannot back up a sleeping server

Velero's schedules run `defaultVolumesToFsBackup: true` over
`includedResources: [pods, persistentvolumeclaims, persistentvolumes]`. Kopia file-system
backup finds volumes **through running pods**, which fails this workload twice over:

1. **A sleeping server has no pod, so its world is skipped entirely.** These servers are
   scaled to zero most of the time, and certainly at 02:00 when the daily schedule fires. The
   worlds would essentially never be captured — and, worse, nothing would report an error,
   because a namespace with no pods is not a failure.
2. **Nothing quiesces the server.** Even for a server that happens to be awake, region files
   are copied while the JVM writes them, which produces a torn world rather than a usable one.

The second problem is the more instructive one: a backup that runs is not the same as a backup
that restores. Minecraft has a documented way to hold a world still — `save-off`, `save-all`,
copy, `save-on` — and any backup that skips it is writing an inconsistent snapshot no matter
what tooling moves the bytes.

So the `minecraft` namespace is excluded from Velero's schedules, and `itzg/mc-backup` runs as
a sidecar instead. Putting the backup **inside the pod** turns the scale-to-zero behaviour from
an obstacle into the schedule: the sidecar exists exactly when the world can change, it holds
RCON to the server it is backing up, and a server nobody visits generates no snapshots because
it has nothing new to say. Each server gets its own restic repository, so two servers waking
together never contend for a lock.

Velero still covers every other namespace. The lesson generalises: **a backup system that
discovers work through running pods silently under-covers anything that scales to zero** —
worth re-checking the day any other workload here starts sleeping.
