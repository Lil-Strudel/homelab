# Media Node

rem-4 is a Dell PowerEdge R730xd that used to be a standalone TrueNAS box. It joined
the cluster as a worker so Jellyfin and the apps that manage the library can run on the
disks that hold it. The hardware is in [Reference → Systems](../reference/systems.md);
running the pool is covered in [Operations → ZFS](../operations/zfs.md).

## ZFS on one node, not Ceph

Ceph replicates everything 3× across the OptiPlex NVMes. That is right for databases and
app state, but a media library would fill that tier for little benefit: it can be
fetched again, and it is read sequentially. A local raidz2 pool keeps about 6 TB of the
8 TB raw, gives local-disk throughput to the transcoder, and puts the library and the
download directories on **one filesystem**. That last point matters most, because the
arr apps rely on hardlinks and atomic renames, which do not work across volumes.

The cost is that the data lives on one host. Losing rem-4 takes the media workloads down
with it. raidz2 covers disk failures, not node failures.

ZFS-LocalPV rather than `hostPath` keeps the pool behind ordinary PVCs. Each volume is
its own dataset with its own properties and snapshots, and the PV's topology pins the
consuming pods to rem-4 with no per-app `nodeAffinity`.

## A software RAID 1 boot mirror

The R730xd's two rear bays used to be a hardware RAID 1 boot pair. The HBA330 is
pass-through with no RAID mode, so the mirror is now Linux MD, which Talos v1.14 can
install onto and boot from (`RAIDArrayConfig`). The array uses metadata 1.0, which
keeps the superblock at the end of each member. That way the partition table is at the
start of both drives, and the firmware can boot from either one.

If one drive dies, the node keeps running and booting on the other. What Talos v1.14
can't do is repair the mirror: no config field or `talosctl` command removes a failed
member or swaps in a new one. Restoring redundancy means running `mdadm` from
`talosctl debug`, or wiping the array (`talosctl wipe md`) and reinstalling. A reinstall
plus `apply-config` takes about 15 minutes. The ZFS pool is on separate disks, and the
zfs extension imports it automatically on the new install. Check the array with
`talosctl -n 10.69.60.24 get mdarraystatuses`.

## Its own schematic

The OptiPlexes run the default-extension schematic. rem-4 needs `zfs`, `i915` and `mei`
(the Arc A40's media engine needs the Management Engine to load HuC), plus `intel-ucode`.
The schematic is committed as `talos/schematics/rem-4.yaml`, and its ID is pinned in
rem-4's machine patch. `upgrade-nodes.sh` reads each node's image from its patch, and
falls back to `patch.yaml`, so an upgrade never puts the cluster schematic on rem-4.

## GPU access

Pods get the Arc A40 through Intel's GPU device plugin, not a `hostPath` of `/dev/dri`.
A `hostPath` device node is not added to the container's device cgroup, so it only works
in a privileged pod; the plugin injects the device properly and lets several pods share
it (`sharedDevNum`). A pod asks for `gpu.intel.com/i915: 1`. The operator lives in
platform-controllers rather than core because its webhooks need cert-manager's CRDs.

Talos has no `render` group, but its udev rules already leave `renderD128` at `0666`,
so pods need no `supplementalGroups`. The card is `card1`/`renderD128`; `card0` is the
on-board Matrox, which has no render node.

Two kernel log lines are worth knowing:

- `HuC: authenticated for all workloads` is the one that matters. DG2 only encodes in
  low-power mode, which needs HuC, and HuC authentication goes through the `mei`
  extension.
- `Using a reduced BAR size of 256MiB` is expected: the R730xd has no Resizable BAR.
  That limits how fast the CPU can reach VRAM. Whether it costs transcoding throughput is
  what the [benchmark](#transcoding) measures.

## Non-Intel optics on the X520

The X520's ixgbe driver refuses SFP+ modules that aren't Intel-coded, and every optic
and DAC here is generic or MikroTik. `ixgbe.allow_unsupported_sfp=1` lifts that. Two
details:

- It is a kernel argument **in the schematic**, not `machine.install.extraKernelArgs`.
  With systemd-boot the command line is baked into the signed UKI, and the machine-config
  field is ignored.
- Mainline ixgbe takes a single boolean. The `=1,1` per-port form belongs to Intel's
  out-of-tree driver.

## Secure Boot by appending to db

The OptiPlexes enrolled Sidero's keys through the Talos ISO, which replaces PK, KEK and
db. Doing that on the R730xd would remove Microsoft's UEFI CA from db, so the HBA330,
X520 and Arc option ROMs would no longer be trusted, and the boot drive behind the HBA
would disappear. Instead, Dell's *Custom* Secure Boot policy is used to **append** the
Image Factory signing certificate to db and leave everything else in place. The steps
are in [Bootstrap → Talos Cluster](../bootstrap/talos.md#adding-rem-4-the-r730xd).

## Fans and the third-party PCIe card

The iDRAC can't read a temperature from a non-Dell PCIe card, so with the Arc installed
it holds the fans at a high fixed floor. Dell documents a raw IPMI command for 13th-gen
servers that disables that response and leaves normal temperature-driven cooling in
place (KB 000135682). The A40 has its own blower and doesn't rely on chassis airflow.

```bash
ipmitool -I lanplus -H 10.69.100.32 -U root -f <(sops -d --extract '["password"]' hardware/idrac.sops.yaml) raw 0x30 0xce 0x00 0x16 0x05 0x00 0x00 0x00 0x05 0x00 0x01 0x00 0x00   # disable
ipmitool -I lanplus -H 10.69.100.32 -U root -f <(sops -d --extract '["password"]' hardware/idrac.sops.yaml) raw 0x30 0xce 0x01 0x16 0x05 0x00 0x00 0x00                             # read: ...05 00 01 00 00 = disabled
```

An iDRAC firmware update or reset to defaults can turn the response back on, so read it
again after either; `racadm get system.thermalsettings` also shows it, as
`ThirdPartyPCIFanResponse`. IPMI over LAN must be enabled on the iDRAC. With the response
off, the fans idle at about 8,400 RPM, down from about 17,000.

## The media stack in one namespace

A PVC belongs to one namespace, and every media app mounts the same library PVC, so they
all live in `media`. That collides with Pod Security: gluetun needs `NET_ADMIN` for its
firewall and routes, and even `baseline` forbids adding it. The namespace therefore
enforces `privileged`, with `warn` and `audit` left at `restricted` so every deviation still
shows up.

A `ValidatingAdmissionPolicy` (`apps/media/admission-policy.yaml`) takes back most of what
`privileged` gives away: no host namespaces, no `hostPath`, no privileged containers, and
the only added capability allowed anywhere is `NET_ADMIN` on a container named `gluetun`.
It is a built-in API, so it needs no CRD and sits beside the apps it guards.

The alternatives were worse:

- **qBittorrent in its own privileged namespace**, reaching the library through a second,
  static PV on the same ZFS volume. The kubelet tracks CSI volumes by driver and volume
  handle, and with ZFS-LocalPV the handle has to be the `ZFSVolume`'s name, so both PVs
  would share one handle. Mount and unmount bookkeeping is not built for that.
- **A PSA exemption by RuntimeClass.** That is an API-server setting, and it exempts any pod
  in any namespace that names the class.
- **gluetun as an HTTP proxy** instead of sharing the pod's network. qBittorrent's DHT and
  uTP are UDP and would either leak or have to be turned off.

## A separate Flux Kustomization

The stack reconciles as `media` (`clusters/main/media.yaml`), not inside `apps`. It is
nearly twenty workloads with large images. With `wait: true`, one slow pull or one
crash-looping app would hold `apps` not-Ready, and Vaultwarden would show as unhealthy
because of a torrent client. On its own, `media` can be slow without hiding problems
elsewhere.

## The VPN is a sidecar, not a node or a gateway

Only qBittorrent goes through the VPN, so the VPN is part of qBittorrent's pod: gluetun
runs as a native sidecar and owns the pod's network namespace. Nothing else in the cluster
changes routing, and the tunnel's lifetime is the pod's. How the layers stack up, and how
to switch to a provider with port forwarding, is in [Operations → Media](../operations/media.md#the-vpn).

`FIREWALL_OUTBOUND_SUBNETS` is deliberately unset. The service CIDR (`10.96.0.0/12`)
overlaps Mullvad's tunnel and DNS range (`10.64.0.0/10`), and it is not needed anyway:
nothing in the pod opens connections into the cluster, and gluetun already routes replies
to inbound connections back out of `eth0`.

## Configuration lives on the node, not on Ceph

Every config PVC in the stack is on the `zfs` class. The apps are pinned to rem-4 by the
library regardless, and rem-4 has no OSD, so `ceph-block` would put every SQLite fsync on
the network for no availability gain: if rem-4 is down, so is everything that would read
that config. Velero's node agent runs on rem-4 and copies those volumes to S3 like any
other.

The library itself is excluded from Velero (`velero.io/exclude-from-backup` on
`media-data`). Everything in it can be fetched again, and it is larger than anything else
in the bucket by orders of magnitude.

## Transcoding

The library is kept as released and transcoded on demand. It is not converted ahead of
time.

Pre-transcoding (Tdarr, Unmanic, or AV1 for space) was rejected:

- It rewrites files. That breaks the hardlink to the seeding torrent and changes what the
  arrs scored, so they grab the release again.
- TRaSH's anime profiles score AV1 at -10000, so converted files fight the guide.
- The Shield, the main TV client, cannot decode AV1, so AV1 would create transcodes rather
  than remove them.

Revisit only for space, when the pool is more than 70% full.

The expectation, before measuring: the Arc Pro A40 has the same media block as the A380
(DG2, two media engines). Community figures for the A380 are about 20 concurrent 1080p
SDR transcodes and 6–8 4K HDR→SDR, and an independent test got about 9 and 3. Against a
peak of 1–3 streams, the GPU should not be the limit. The likely limit is CPU-side libass,
when the official Android TV app burns in ASS subtitles on anime.

The decision rule:

| Result | Then |
| --- | --- |
| The mix (two ASS-anime burn-ins plus one 4K HDR tone-map) holds 1.2× or better | Keep transcoding on demand. Done |
| ASS burn-in falls short, on CPU | Fix it at the client: Kodi + JellyCon on the Shield, mpv or Findroid on phones. Never pre-burn subtitles |
| 4K HDR tone-mapping falls short | Keep 4K to the opt-in "max" profiles, so it stays rare |

Measured results (procedure in [Operations → Media](../operations/media.md#benchmark)):

| Case | Ceiling (N at ≥1.0×) | Sustainable (N at ≥1.2×) | Bottleneck |
| --- | --- | --- | --- |
| A: 1080p HEVC 10-bit + ASS burn-in → H.264 | not yet measured | | |
| B: 4K HDR10 → 1080p SDR | not yet measured | | |
| C: 1080p → 720p 4 Mbps | not yet measured | | |
| Mix: 2×A + 1×B | not yet measured | | |
