# Upgrades

Most bumps arrive as **Renovate PRs** — the `flux` manager watches `HelmRelease` chart
versions and image tags in `kubernetes/**`, and `customManagers` in `renovate.json`
watch versions pinned in raw manifests and docs. Merging a PR is the normal path; major
bumps wait on dashboard approval. The current pins and their homes are in
[Reference → Versions](../reference/versions.md).

A few components need a manual step because a version drives generated content or is
pinned in more than one place:

## Talos / Kubernetes

The Talos installer tag (`talos/patch.yaml`) and `--kubernetes-version`
(`talos/gen-talos-objects.sh`) must move together — a Talos release pins its Kubernetes
version, so read it off the [Talos release](https://github.com/siderolabs/talos/releases)
and update both the Talos and Kubernetes rows in
[Reference → Versions](../reference/versions.md). After changing them, regenerate and
re-apply from `talos/`:

```bash
./gen-talos-objects.sh
./gen-machine-configs.sh
./apply-config-all-nodes.sh
```

Roll nodes one at a time; Talos handles the rest.

## Cilium

The chart version in `controllers/cilium/helm-release.yaml` and the `--version` in the
[bootstrap `helm install`](../bootstrap/cluster.md) must stay identical. Renovate's
custom manager updates both; if you bump by hand, change both.

## kube-vip

The image tag is the version pin. **Don't hand-edit the manifest** — regenerate it so
it stays byte-pristine, per [Decisions → kube-vip](../decisions/kube-vip.md). Re-run the
generator with the new tag; the only expected diff is the tag itself.

## Rook-Ceph

All three charts move in **lockstep**. Set the operator and cluster charts to the new
`vX.Y.Z`, read that release's `ceph-csi-operator` dependency version out of `Chart.yaml`,
and set `ceph-csi-drivers` to it. Re-fetch and diff the upstream `ceph-csi-drivers`
values on a bump. Full procedure and verification commands are in
[Decisions → Rook-Ceph Values](../decisions/rook-ceph.md).

## Observability

The four charts (`victoria-metrics-k8s-stack`, `loki`, `grafana`, `alloy`) are ordinary
Renovate bumps with no manual step — but two details govern how they are wired:

- The VictoriaMetrics stack ships its CRDs in Helm's `crds/` directory, which Helm alone
  never updates on upgrade. Its `HelmRelease` sets `upgrade.crds: CreateReplace` so a
  chart bump carries the operator's CRD changes with it; leaving that out silently pins
  the CRDs at whatever the first install laid down.
- Loki and Alloy come from the `grafana` Helm repo, Grafana itself from
  `grafana-community`. A Renovate entry that points at the wrong one finds no versions
  and quietly stops updating — see the entries in `renovate.json`.

## Flux

Bump `--version` in the [bootstrap command](../bootstrap/cluster.md) and re-run
`flux bootstrap` with a **matching local CLI** (`flux version --client`) — the CLI
regenerates `gotk-components.yaml`. A mismatched CLI rewrites that file incorrectly.
