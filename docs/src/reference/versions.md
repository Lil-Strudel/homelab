# Versions

Every pinned version, and the file that pins it. This table and the manifests it
points at (the "Pinned in" column) are the **only** places version numbers live —
every other doc uses placeholders and links here. Bumps are handled by Renovate (see
[Upgrades](../operations/upgrades.md)); Renovate updates this table *and* the manifest
in lockstep, so the two never drift.

| Component | Version | Pinned in |
| --- | --- | --- |
| Talos Linux | `v1.14.2` | `talos/patch.yaml` (installer image tag) |
| Kubernetes | `1.36.5` | `talos/gen-talos-objects.sh` (`--kubernetes-version`) |
| Cilium | `1.20.2` | `kubernetes/infrastructure/core/controllers/cilium/helm-release.yaml` |
| Flux | `v2.9.6` | `flux bootstrap --version` + `clusters/main/flux-system/gotk-components.yaml` |
| kube-vip | `v1.2.4` | `kubernetes/infrastructure/core/controllers/kube-vip/kube-vip.yaml` (image tag) |
| Rook (operator + cluster) | `v1.21.0` | `core/controllers/rook-ceph/operator.yaml` + `core/configs/rook-ceph/cluster.yaml` |
| ceph-csi-drivers | `1.1.0` | `core/controllers/rook-ceph/csi-drivers.yaml` |
| Ceph | `v20.2.4` (Tentacle) | `core/configs/rook-ceph/cluster.yaml` (`cephImage.tag`) |
| cert-manager | `v1.21.2` | `core/controllers/cert-manager/oci-repo.yaml` (`ref.tag`) |
| Velero | `12.2.1` | `platform/controllers/velero/helm-release.yaml` (chart version) |
| velero-plugin-for-aws | `v1.14.4` | `platform/controllers/velero/helm-release.yaml` (`initContainers` image tag) |
| aws-cli | `2.37.12` | `platform/controllers/ddns/cronjob.yaml` (image tag) |
| victoria-metrics-k8s-stack | `0.95.2` | `platform/controllers/victoria-metrics/helm-release.yaml` (chart version) |
| Loki | `7.3.0` | `platform/controllers/loki/helm-release.yaml` (chart version) |
| Grafana | `13.5.0` | `platform/controllers/grafana/helm-release.yaml` (chart version) |
| Grafana Alloy | `1.13.1` | `platform/controllers/alloy/helm-release.yaml` (chart version) |
| CloudNativePG | `0.29.1` | `platform/controllers/cnpg/operator.yaml` (chart version) |
| plugin-barman-cloud | `0.8.1` | `platform/controllers/cnpg/plugin-barman-cloud.yaml` (chart version) |
| PostgreSQL | `18-standard-trixie` | `platform/configs/cnpg/image-catalog.yaml` (tag + digest) |
| mdBook | `v0.5.4` | `.github/workflows/docs.yml` (`MDBOOK_VERSION`) |

## Pins that must move together

- **Talos ↔ Kubernetes** — each Talos release supports a range of Kubernetes versions;
  `--kubernetes-version` in `gen-talos-objects.sh` must sit inside the range of the Talos
  tag in `patch.yaml` (check the Talos support matrix). The two upgrade separately.
  Renovate tracks Talos, not Kubernetes, so the Kubernetes row is bumped by hand after
  `talosctl upgrade-k8s` — see [Talos & Kubernetes Upgrades](../operations/talos-upgrades.md).
- **Cilium chart ↔ bootstrap `helm install`** — the chart version in the `HelmRelease`
  must equal the `--version` in the [Cilium + Flux bootstrap](../bootstrap/cluster.md).
- **Rook operator ↔ cluster ↔ csi-drivers** — all move in lockstep; see
  [Rook-Ceph Values](../decisions/rook-ceph.md).
- **kube-vip image tag** — the generator command and the committed manifest carry the
  same tag; see [kube-vip Manifest](../decisions/kube-vip.md).
