# Creating the Rook-Ceph Config

Rook-Ceph is installed with **Helm**, driven by Flux `HelmRelease`s — not with
raw manifests. So unlike [kube-vip](./creating-kube-vip-manifest.md), there is no
generated YAML to keep byte-pristine; the committed artifact is the **values**,
and the discipline is different: every value we set is either a genuine
divergence from the chart default or a deliberate pin, each one documented, and
the one values file we copy from upstream is copied **verbatim with a source
link**. This note records where every version and value comes from so the config
stays reproducible and auditable.

## The three charts and their versions

Rook v1.20 splits into three charts across two repos. All Rook version numbers
move together; the CSI pieces track the operator chart's pinned subchart.

| HelmRelease | Chart | Repo | Version | Source of the version |
| --- | --- | --- | --- | --- |
| `ceph-operator` | `rook-ceph` | `charts.rook.io/release` | `v1.20.2` | Latest release; chart `appVersion` = operator image `v1.20.2` |
| `ceph-cluster` | `rook-ceph-cluster` | `charts.rook.io/release` | `v1.20.2` | Must match the operator chart exactly |
| `ceph-csi-drivers` | `ceph-csi-drivers` | `ceph.github.io/ceph-csi-operator` | `1.0.4` | The `ceph-csi-operator` dependency the `rook-ceph` chart pins |

Two version-string conventions live side by side, and both are intentional — each
pin matches the string its own repo publishes:

- Rook charts publish **with** a `v` prefix (`v1.20.2`).
- The ceph-csi-operator charts publish **without** one (`1.0.4`).

Verify the pins against the published indexes:

```bash
# Rook chart version + the operator image (appVersion) it ships:
curl -sL https://charts.rook.io/release/rook-ceph-v1.20.2.tgz \
  | tar -xzO rook-ceph/Chart.yaml | grep -E '^version|^appVersion'
# -> version: v1.20.2   appVersion: v1.20.2

# The ceph-csi-operator subchart version the rook-ceph chart depends on:
curl -sL https://charts.rook.io/release/rook-ceph-v1.20.2.tgz \
  | tar -xzO rook-ceph/Chart.yaml | grep -A2 'name: ceph-csi-operator'
# -> version: 1.0.4
```

Bumping Rook means moving all three in lockstep: set the operator and cluster
charts to the new `vX.Y.Z`, read that release's `ceph-csi-operator` dependency
version out of `Chart.yaml`, and set the `ceph-csi-drivers` chart to it.

## The CSI model changed in v1.20

The operator **no longer deploys the CSI drivers**. The flow is now three steps
([operator chart docs](https://rook.io/docs/rook/v1.20/Helm-Charts/operator-chart/)):

1. The `rook-ceph` chart installs the operator **and** the `ceph-csi-operator`
   subchart + its CRDs (`csi.installCsiOperator: true`, the chart default).
2. The `ceph-csi-drivers` chart creates the `Driver` CRs the ceph-csi-operator
   reconciles into RBD/CephFS provisioners. **Required** — without it, provisioning
   fails and the StorageClasses have no driver behind them.
3. The `rook-ceph-cluster` chart creates the `CephCluster`, pools, and SCs.

### `ceph-csi-drivers` values — copied verbatim from upstream

Rook publishes a **required** recommended values file for this chart, and warns
the drivers *"will fail if only configured with the chart defaults"* (the default
driver names lack the `rook-ceph.` prefix the StorageClasses expect, and the
image set isn't wired up). We copy it verbatim into the `ceph-csi-drivers`
HelmRelease `values:`. Source — re-fetch and diff on a bump:

```bash
curl -sL https://raw.githubusercontent.com/rook/rook/v1.20.2/deploy/charts/ceph-csi-drivers/values.yaml
```

The load-bearing bits: driver names carry the operator-namespace prefix
(`rook-ceph.{rbd,cephfs}.csi.ceph.com`) to match the provisioner names the
cluster chart bakes into its StorageClasses, and `imageSet.name:
rook-csi-operator-image-set-configmap` points the drivers at the CSI sidecar
images the **operator** chart pins (cephcsi, provisioner, attacher, …) rather
than the ceph-csi-operator's own defaults. NFS and NVMe-oF are disabled.

## Auditing the values against defaults

The rule for the operator and cluster charts: **only genuine divergences and
deliberate pins appear in `values:`.** A value that merely restates the v1.20.2
chart default is noise and was removed. To reproduce the audit, diff our
overrides against the published defaults:

```bash
# Operator chart defaults:
curl -sL https://raw.githubusercontent.com/rook/rook/v1.20.2/deploy/charts/rook-ceph/values.yaml
# Cluster chart defaults:
curl -sL https://raw.githubusercontent.com/rook/rook/v1.20.2/deploy/charts/rook-ceph-cluster/values.yaml
```

### `ceph-operator` — no overrides

Everything we might pin already equals the v1.20.2 default for our setup, so the
HelmRelease carries **no `values:` block**:

- `crds.enabled: true`, `csi.installCsiOperator: true` — both default `true`.
- `csi.kubeletDirPath: /var/lib/kubelet` — the default, and where Talos keeps
  the kubelet dir, so no override is needed.
- Operator image tag defaults to the chart `appVersion` (`v1.20.2`), which the
  chart version pin already fixes.

### `ceph-cluster` — the divergences we keep

| Value | Default | Why we set it |
| --- | --- | --- |
| `cephImage.tag: v20.2.2` | `v20.2.2` | **Pin, not divergence.** Guards against a future chart bump silently moving the Ceph data-plane version. Matches today's default. |
| `toolbox.enabled: true` | `false` | Debug shell (`ceph -s`) on a single-admin homelab. |
| `cephClusterSpec.dashboard.enabled: true` | `true` | **Pin.** An explicit requirement; kept so a default change can't silently disable it. HTTPS + `ssl: true` are chart defaults. |
| `cephClusterSpec.placement.all.tolerations` | none | Tolerate `node-role.kubernetes.io/control-plane:NoSchedule` (Talos taint) so OSDs schedule on all six nodes, not just workers. |
| `cephClusterSpec.storage` (`useAllDevices: false`, `deviceFilter: ^nvme0n1`) | `useAllDevices: true`, no filter | Claim only the 1 TB data NVMe, never the OS disk. Default would grab every disk. |
| `cephObjectStores: []` | one `ceph-objectstore` entry | Disable RGW/S3 + the `ceph-bucket` SC — nothing consumes buckets. |

### What we deliberately **inherit** (removed from `values:`)

- **The block pool and filesystem.** The chart default already defines exactly
  what we want: `ceph-blockpool` → `ceph-block` (RWO, the cluster-default SC) and
  `ceph-filesystem` (RWX), both `size: 3` / `failureDomain: host`, one active MDS
  + hot standby. The previous config re-specified both — and in doing so **dropped
  the `csi.storage.k8s.io/controller-publish-secret-*` StorageClass parameters**
  the real defaults include. Helm replaces list values wholesale, so a partial
  restatement silently loses keys. Inheriting the default is both more minimal and
  strictly more correct.
- `mon.count: 3`, `mgr.count: 2`, `operatorNamespace: rook-ceph` — all already the
  defaults.

## Deployed by Flux

`ceph-operator` and `ceph-csi-drivers` live in `infrastructure/controllers`
(after cilium, whose CNI the pods need); `ceph-cluster` and the dashboard
LoadBalancer live in `infrastructure/configs`. `infra-controllers` runs with
`wait: true`, so the operator and CSI drivers are healthy before the
`CephCluster` reconciles. The operational side — dashboard access, health checks,
disk expectations — is in [Rook-Ceph Setup](./rook-ceph-setup.md).
