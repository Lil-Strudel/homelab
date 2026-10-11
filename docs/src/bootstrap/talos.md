# 2. Talos Cluster

Bring up the OS and Kubernetes control plane. Versions (Talos, Kubernetes) are in
[Reference → Versions](../reference/versions.md); the design is in
[Architecture → Talos](../architecture.md#2-operating-system--talos-linux).

Get the Secure Boot ISO for the pinned Talos version from the
[Talos factory](https://factory.talos.dev/?arch=amd64&board=undefined&cmdline-set=true&extensions=-&platform=metal&secureboot=true&target=metal),
schematic `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba` (Secure
Boot, default extensions) — the same schematic pinned as the installer image in
`talos/patch.yaml`.

> **First bring-up only:** the control-plane VIP (`10.69.60.10`) is owned by kube-vip,
> which isn't running yet. Set a temporary dst-nat on the MikroTik pointing
> `10.69.60.10` → `10.69.60.11` so the endpoint resolves during bootstrap; remove it
> once kube-vip is up.

From `talos/`:

```bash
./gen-talos-objects.sh     # secrets + controlplane/worker/talosconfig from the patches
./gen-machine-configs.sh   # per-node machine-configs/
```

The configs use Talos's multi-document format. Each concern is its own document
rather than a field of the `v1alpha1` document: the installer image and install disk
live in `UnattendedInstallConfig`, and the Kubernetes settings in the `Kube*Config`
documents. `patch.yaml` applies to every node. `controlplane-patch.yaml` applies to
the control plane only, because `KubeProxyConfig` and `KubeFlannelCNIConfig` are
control-plane documents. It deletes Flannel and disables kube-proxy so Cilium can
replace both.

Nodes installed before v1.14 still run the old single-document format (`machine.install`,
`cluster.network.cni`, `cluster.proxy`). Talos accepts both. A node moves to the new
format the next time its regenerated config is applied with `talosctl apply-config`.

Boot each node into the Talos ISO, enrol the Secure Boot keys on the boot page, then
boot the ISO again. Apply the config to each node:

```bash
talosctl apply-config --insecure -n 10.69.60.11 --file machine-configs/makima-1.yaml
```

...or, if Talos is already installed and every node is in maintenance mode:

```bash
./apply-config-all-nodes.sh
```

Bootstrap etcd on the first control-plane node, then pull the kubeconfig:

```bash
talosctl bootstrap  -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
talosctl kubeconfig -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
```

Nodes stay `NotReady` until a CNI is installed — continue to
[Cilium + Flux](./cluster.md).

## Adding rem-4 (the R730xd)

rem-4 joins a running cluster; it is never part of a from-scratch bootstrap order. It
differs from the OptiPlexes in three ways, all explained in
[Decisions → Media Node](../decisions/media-node.md):

- **Its own schematic**, `talos/schematics/rem-4.yaml`: ZFS, the Intel GPU drivers
  (`i915`, `mei`), `intel-ucode`, and the X520 optics kernel argument. Register it and
  get its ID with
  `curl -X POST --data-binary @talos/schematics/rem-4.yaml https://factory.talos.dev/schematics`.
  The ID goes into the installer image in `talos/machine-patches/rem-4-patch.yaml`;
  download the Secure Boot ISO for the same schematic.
- **Secure Boot keys are appended, not enrolled.** Talos's ISO enrolment replaces the
  UEFI key databases, which would also drop Microsoft's CA, and with it the HBA330, X520
  and Arc option ROMs. Instead, in BIOS Setup set *Secure Boot Policy* to **Custom**,
  and under *Custom Policy Settings* import the Image Factory signing certificate into
  **db**, leaving PK, KEK and the existing db entries alone:
  ```bash
  curl -s https://factory.talos.dev/secureboot/signing-cert.pem | openssl x509 -outform der -out talos-factory.der
  ```
  Put the `.der` on a FAT USB stick (or a PiKVM mass-storage image), import it, then
  enable Secure Boot before booting the ISO.
- **Talos installs onto a RAID 1 mirror of the two rear drives.** A `RAIDArrayConfig`
  in the rem-4 patch selects both drives by serial, and the install disk is the array
  rather than a single drive. The cluster-wide selector (`disk.model == "Samsung SSD 870"`)
  would match the front pool drives too, so the rem-4 patch overrides it. The serials
  come from the iDRAC (`racadm storage get pdisks`) or from
  `talosctl get disks --insecure -n 10.69.60.24` while the ISO is in maintenance mode.
  When the config is applied in maintenance mode, Talos builds the array, waits for it,
  and installs onto it.

The node's DHCP lease and BGP peer are in `terraform/main.tf`; apply those first so it
comes up on `10.69.60.24`. Then, from `talos/`:

```bash
./gen-talos-objects.sh && ./gen-machine-configs.sh
talosctl apply-config --insecure -n 10.69.60.24 --file machine-configs/rem-4.yaml
```

`gen-talos-objects.sh` re-encrypts `talos/talosconfig.sops.yaml` with new ciphertext but
unchanged content; discard that diff rather than committing it. Once the node is
`Ready`, create the pool: [Operations → ZFS](../operations/zfs.md).
