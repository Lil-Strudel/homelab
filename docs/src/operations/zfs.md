# Storage (ZFS)

rem-4 carries one ZFS pool, `phyllo`, on its eight front 870 EVOs. Kubernetes reaches it
through [OpenEBS ZFS-LocalPV](https://github.com/openebs/zfs-localpv), which turns each
PVC into a dataset under `phyllo/k8s`. The design is in
[Architecture → Storage](../architecture.md#storage); why ZFS on one node instead of Ceph
is in [Decisions → Media Node](../decisions/media-node.md). Versions are in
[Reference → Versions](../reference/versions.md).

## What runs where

| Piece | Where | Role |
| --- | --- | --- |
| `zfs` system extension | rem-4's Talos schematic | Kernel module, `zpool`/`zfs` tools, and a service that imports every pool at boot |
| `zfs-localpv` HelmRelease | core-controllers, namespace `openebs` | CSI controller (any node) and node plugin (rem-4 only) + CRDs, including the VolumeSnapshot CRDs |
| StorageClass `zfs` | core-configs | `phyllo/k8s`, lz4, `Retain`, `WaitForFirstConsumer`, topology pinned to rem-4 |

The node plugin runs the host's own `zfs` binary through a chroot, so the userland always
matches the kernel module that the Talos extension ships.

## What you can claim

| Want | Use | Behaviour |
| --- | --- | --- |
| A dataset on the pool | StorageClass `zfs` | The PV is pinned to rem-4, so any pod mounting it schedules there |

A `ReadWriteOnce` volume is per *node*, not per pod, so several pods on rem-4 can mount
the same PVC. That is how media and the apps that manage it share one dataset and get
hardlinks and atomic moves across it.

`reclaimPolicy` is `Retain`: deleting a PVC leaves the dataset and the `ZFSVolume` in
place. Delete the PV, then `zfs destroy` the dataset, when the data is really unwanted.

## Running zfs and zpool

Talos has no shell, so run the tools from a privileged debug pod that chroots into the
host:

```bash
kubectl -n kube-system debug -it --profile sysadmin --image=alpine node/rem-4
chroot /host zpool status
```

## Creating the pool

Done once per pool, on drives holding nothing you want.

1. List the front drives by stable ID (the rear drives are Talos's RAID 1 mirror;
   leave them alone):
   ```bash
   chroot /host ls -l /dev/disk/by-id/ | grep -v part
   ```
2. If the boot-time importer brought in an old pool, check with `zpool status` and
   remove it with `zpool destroy <POOL>`.
3. Clear every front drive. `<ID>` is each drive's `/dev/disk/by-id` name: the host's
   tools see it under `/dev`, and the pod's tools see it under `/host/dev`.
   ```bash
   apk add util-linux
   chroot /host zpool labelclear -f /dev/disk/by-id/<ID>
   wipefs -a /host/dev/disk/by-id/<ID>
   blkdiscard -f /host/dev/disk/by-id/<ID>
   ```
   The two clone drives in bays 6–7 don't support TRIM, so `blkdiscard` fails on them
   with `Operation not supported`. `wipefs` is enough there. The pool's `autotrim`
   skips them the same way.
4. Create the pool and the parent dataset for the CSI driver:
   ```bash
   chroot /host zpool create -o ashift=12 -o autotrim=on \
     -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
     -O mountpoint=/var/mnt/phyllo \
     phyllo raidz2 /dev/disk/by-id/<ID_1> ... /dev/disk/by-id/<ID_8>
   chroot /host zfs create phyllo/k8s
   ```
   Mountpoints must be under `/var`; the rest of the Talos root filesystem is read-only.
5. Reboot (`talosctl -n 10.69.60.24 reboot`) and check that `zpool status phyllo` is
   `ONLINE`. That confirms the extension's importer brings the pool back by itself.

## Replacing a drive

```bash
chroot /host zpool status phyllo                   # find the FAULTED/UNAVAIL member
chroot /host zpool replace phyllo <OLD_DISK> <NEW_DISK>
chroot /host zpool status phyllo                   # watch the resilver
```

raidz2 keeps serving with two drives missing, but replace the first one promptly. The
pool has no hot spare.

## Health check

```bash
chroot /host zpool status -x                       # "all pools are healthy"
chroot /host zpool list
chroot /host zfs list -r phyllo/k8s
kubectl -n openebs get pods
kubectl get zfsvolumes -A
```

## Not backed up yet

Velero's S3 backups cover Ceph PVCs, but nothing copies `phyllo` off the node yet. A lost
node or pool means lost data, so only keep media that can be fetched again until
off-node backups exist.
