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
again after either. IPMI over LAN must be enabled on the iDRAC.
