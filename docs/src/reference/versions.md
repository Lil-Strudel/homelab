# Versions

Every pinned version, and the file that pins it. This table and the manifests it
points at (the "Pinned in" column) are the **only** places version numbers live —
every other doc uses placeholders and links here. Bumps are handled by Renovate (see
[Upgrades](../operations/upgrades.md)); Renovate updates this table *and* the manifest
in lockstep, so the two never drift.

| Component | Version | Pinned in |
| --- | --- | --- |
| Talos Linux | `v1.13.7` | `talos/patch.yaml` (installer image tag) |
| Kubernetes | `1.36.2` | `talos/gen-talos-objects.sh` (`--kubernetes-version`) + `talos/patch.yaml` installer tag |
| Cilium | `1.19.6` | `kubernetes/infrastructure/controllers/cilium/helm-release.yaml` |
| Flux | `v2.9.3` | `flux bootstrap --version` + `clusters/main/flux-system/gotk-components.yaml` |
| kube-vip | `v1.2.1` | `kubernetes/infrastructure/controllers/kube-vip/kube-vip.yaml` (image tag) |
| Rook (operator + cluster) | `v1.20.2` | `controllers/rook-ceph/operator.yaml` + `configs/rook-ceph/cluster.yaml` |
| ceph-csi-drivers | `1.0.4` | `controllers/rook-ceph/csi-drivers.yaml` |
| Ceph | `v20.2.2` (Tentacle) | `configs/rook-ceph/cluster.yaml` (`cephImage.tag`) |
| cert-manager | `v1.21.1` | `controllers/cert-manager/oci-repo.yaml` (`ref.tag`) |
| Velero | `12.1.0` | `controllers/velero/helm-release.yaml` (chart version) |
| velero-plugin-for-aws | `v1.14.2` | `controllers/velero/helm-release.yaml` (`initContainers` image tag) |

## Pins that must move together

- **Talos ↔ Kubernetes** — the Talos installer tag in `patch.yaml` and
  `--kubernetes-version` in `gen-talos-objects.sh` must stay in sync (a Talos release
  pins its Kubernetes version). Renovate tracks Talos, not Kubernetes; bump the
  Kubernetes row by hand alongside a Talos bump.
- **Cilium chart ↔ bootstrap `helm install`** — the chart version in the `HelmRelease`
  must equal the `--version` in the [Cilium + Flux bootstrap](../bootstrap/cluster.md).
- **Rook operator ↔ cluster ↔ csi-drivers** — all move in lockstep; see
  [Rook-Ceph Values](../decisions/rook-ceph.md).
- **kube-vip image tag** — the generator command and the committed manifest carry the
  same tag; see [kube-vip Manifest](../decisions/kube-vip.md).
