# Rook-Ceph Values

Rook-Ceph is installed with **Helm** via Flux `HelmRelease`s, so — unlike
[kube-vip](./kube-vip.md) — there's no generated YAML to keep byte-pristine; the
committed artifact is the **values**. The discipline: every value we set is a genuine
divergence from the chart default or a deliberate pin, each documented, and the one
file copied from upstream is copied **verbatim with a source link**. Versions live in
[Reference → Versions](../reference/versions.md); operations in
[Operations → Storage](../operations/storage.md).

## The three charts

Rook v1.20 splits into three charts across two repos. All Rook version numbers move
together; the CSI pieces track the operator chart's pinned subchart.

| HelmRelease | Chart | Repo | Version source |
| --- | --- | --- | --- |
| `ceph-operator` | `rook-ceph` | `charts.rook.io/release` | Latest release; chart `appVersion` = operator image |
| `ceph-cluster` | `rook-ceph-cluster` | `charts.rook.io/release` | Must match the operator chart exactly |
| `ceph-csi-drivers` | `ceph-csi-drivers` | `ceph.github.io/ceph-csi-operator` | The `ceph-csi-operator` dependency the `rook-ceph` chart pins |

Two version-string conventions live side by side, both intentional: Rook charts publish
**with** a `v` prefix, the ceph-csi-operator charts **without** one — the exact strings
are in [Reference → Versions](../reference/versions.md). Commands below use
`<ROOK_VERSION>` (the Rook pin) and `<CEPH_VERSION>` (the Ceph pin) from that table.

Verify the pins against the published indexes:

```bash
# Rook chart version + the operator image (appVersion) it ships:
curl -sL https://charts.rook.io/release/rook-ceph-<ROOK_VERSION>.tgz \
  | tar -xzO rook-ceph/Chart.yaml | grep -E '^version|^appVersion'
# The ceph-csi-operator subchart version the rook-ceph chart depends on:
curl -sL https://charts.rook.io/release/rook-ceph-<ROOK_VERSION>.tgz \
  | tar -xzO rook-ceph/Chart.yaml | grep -A2 'name: ceph-csi-operator'
```

**Bumping = moving all three in lockstep:** set operator + cluster to the new `vX.Y.Z`,
read that release's `ceph-csi-operator` dependency out of `Chart.yaml`, and set
`ceph-csi-drivers` to it.

## The CSI model changed in v1.20

The operator **no longer deploys the CSI drivers**
([operator chart docs](https://rook.io/docs/rook/v1.20/Helm-Charts/operator-chart/)):

1. `rook-ceph` installs the operator **and** the `ceph-csi-operator` subchart + CRDs
   (`csi.installCsiOperator: true`, the default).
2. `ceph-csi-drivers` creates the `Driver` CRs the ceph-csi-operator reconciles into
   provisioners. **Required** — without it, provisioning fails and the StorageClasses
   have no driver behind them.
3. `rook-ceph-cluster` creates the `CephCluster`, pools, and SCs.

### `ceph-csi-drivers` values — copied verbatim

Rook publishes a **required** recommended values file and warns the drivers *"will fail
if only configured with the chart defaults."* We copy it verbatim into the HelmRelease
`values:`. Re-fetch and diff on a bump:

```bash
curl -sL https://raw.githubusercontent.com/rook/rook/<ROOK_VERSION>/deploy/charts/ceph-csi-drivers/values.yaml
```

The load-bearing bits: driver names carry the operator-namespace prefix
(`rook-ceph.{rbd,cephfs}.csi.ceph.com`) to match the provisioner names the cluster chart
bakes into its StorageClasses, and `imageSet.name` points the drivers at the CSI sidecar
images the **operator** chart pins rather than the ceph-csi-operator's own defaults. NFS
and NVMe-oF are disabled.

## Auditing values against defaults

Rule for the operator and cluster charts: **only genuine divergences and deliberate pins
appear in `values:`.** A value that merely restates a chart default is noise and was
removed. To reproduce the audit:

```bash
curl -sL https://raw.githubusercontent.com/rook/rook/<ROOK_VERSION>/deploy/charts/rook-ceph/values.yaml
curl -sL https://raw.githubusercontent.com/rook/rook/<ROOK_VERSION>/deploy/charts/rook-ceph-cluster/values.yaml
```

### `ceph-operator` — no overrides

Everything we might pin already equals the chart default for our setup, so the
HelmRelease carries **no `values:` block** (`crds.enabled` / `csi.installCsiOperator`
default `true`; `csi.kubeletDirPath: /var/lib/kubelet` is the default and where Talos
keeps the kubelet dir; the operator image tag defaults to `appVersion`, fixed by the
chart pin).

### `ceph-cluster` — the divergences we keep

| Value | Default | Why we set it |
| --- | --- | --- |
| `cephImage.tag` (the Ceph pin) | same as chart default | **Pin, not divergence.** Guards against a chart bump silently moving the Ceph data-plane version. |
| `toolbox.enabled: true` | `false` | Debug shell (`ceph -s`) on a single-admin homelab. |
| `dashboard.enabled: true` | `true` | **Pin.** Explicit requirement; kept so a default change can't disable it. |
| `placement.all.tolerations` | none | Tolerate the Talos control-plane taint so OSDs schedule on all six nodes. |
| `storage` (`useAllDevices: false`, `deviceFilter: ^nvme0n1`) | `useAllDevices: true` | Claim only the 1 TB data NVMe, never the OS disk. |
| `cephObjectStores: []` | one entry | Disable RGW/S3 + the `ceph-bucket` SC — nothing consumes buckets. |

### What we deliberately **inherit** (removed from `values:`)

- **The block pool and filesystem.** The chart default already defines exactly what we
  want: `ceph-blockpool` → `ceph-block` (RWO, cluster-default SC) and `ceph-filesystem`
  (RWX), both `size: 3` / `failureDomain: host`. The previous config re-specified both
  and in doing so **dropped the `csi.storage.k8s.io/…-secret-*` StorageClass
  parameters** the real defaults include — Helm replaces list values wholesale, so a
  partial restatement silently loses keys. Inheriting is more minimal *and* more correct.
- `mon.count: 3`, `mgr.count: 2`, `operatorNamespace: rook-ceph` — all already defaults.
