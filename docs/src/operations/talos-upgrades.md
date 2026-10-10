# Talos & Kubernetes Upgrades

Talos and Kubernetes upgrade separately, and neither goes through Flux. `talosctl upgrade`
replaces the OS on one node at a time; `talosctl upgrade-k8s` moves the control plane and
every kubelet to a new Kubernetes version. Renovate only bumps the pins — the installer
tag in `talos/patch.yaml` and the rows in [Reference → Versions](../reference/versions.md);
merging that PR changes nothing on the nodes. Versions below are placeholders
(`<TALOS_VERSION>`, `<K8S_VERSION>`); the current pins are in the versions table.

Upstream references:
[Upgrading Talos](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos),
[Upgrading Kubernetes](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes),
[Support matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix).

## Before you start

1. **Pick the path.** Talos: *"The recommended upgrade path is to always upgrade to the
   latest patch release of all intermediate minor releases."* Moving to a new minor
   therefore takes two hops: first the newest patch of the current minor, then the
   target ([upgrade log](#upgrade-log) has a worked example). Read the *What's New* page
   of every minor you cross for breaking changes and deprecated config fields.
2. **Check Kubernetes compatibility.** A Talos minor ships a newer default Kubernetes, but
   upgrading Talos never changes the Kubernetes version. Before moving Kubernetes to a new
   minor, confirm every core component lists it as supported — Cilium, cert-manager, Rook
   and ceph-csi, CloudNativePG. Cilium is usually the last.
3. **Update the client.** `talosctl` should be at least the target Talos version
   (`talosctl version --client`).
4. **Confirm the cluster is healthy.** All nodes `Ready`, every Flux Kustomization and
   HelmRelease `Ready`, and Ceph reporting every PG `active+clean`:

   ```bash
   kubectl get nodes
   flux get ks; flux get hr -A
   kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg stat
   ```

5. **Snapshot etcd.** Keep the file outside the repo; it holds every Secret in the cluster.

   ```bash
   talosctl -n 10.69.60.11 -e 10.69.60.11 --talosconfig talos/talosconfig \
     etcd snapshot ~/etcd-$(date +%F).snapshot
   ```

## Upgrade Talos

Run from `talos/`, once per hop on the path:

```bash
./upgrade-nodes.sh <TALOS_VERSION>            # every node, control planes first
./upgrade-nodes.sh <TALOS_VERSION> rem-2      # or just the named nodes
```

For each node the script waits for Ceph to be clean, sets `noout`, runs `talosctl
upgrade`, then clears `noout` and waits for Ceph to be clean again before moving on. Nodes
already on the target version are skipped, so after a failure, fix the cause and re-run
the same command.

`talosctl upgrade` itself writes the new image to the inactive boot slot, cordons and
drains the node, reboots it, waits for it to rejoin as `Ready`, and uncordons it. The
equivalent by hand, for one node:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set noout
talosctl -n <NODE_IP> -e <ENDPOINT_IP> --talosconfig talos/talosconfig upgrade \
  -i factory.talos.dev/metal-installer-secureboot/<SCHEMATIC>:<TALOS_VERSION> --wait
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset noout
```

Three details matter:

- **The installer image must be the Secure Boot schematic.** Without `-i`, `talosctl`
  defaults to the plain `metal-installer` image, which is the wrong one for these nodes.
  The schematic is the one in `talos/patch.yaml`; see [Talos Cluster](../bootstrap/talos.md).
- **Workers need a control-plane endpoint.** `talosctl` fetches a kubeconfig from the
  endpoint to drain the node, and only control-plane nodes serve one. With `-e` pointed at
  a worker, the image installs but the drain fails and the node never reboots. Pass the
  worker in `-n` and a control-plane node in `-e`.
- **One node at a time, control planes first.** etcd keeps quorum with one member down,
  and every node carries an OSD, so Ceph can lose only one host at a time. `noout` stops
  Ceph from re-replicating a rebooting node's data; that node simply rejoins.

When the hop is done, merge (or make) the pin change in `talos/patch.yaml` and the Talos
row of `versions.md`, then point the live machine configs at the same image —
`talosctl upgrade` does not touch `machine.install.image`, which otherwise keeps
naming the version each node was first installed with:

```bash
for ip in 10.69.60.11 10.69.60.12 10.69.60.13 10.69.60.21 10.69.60.22 10.69.60.23; do
  talosctl -n $ip -e 10.69.60.11 --talosconfig talos/talosconfig patch machineconfig --mode=no-reboot \
    --patch 'machine: {install: {image: factory.talos.dev/metal-installer-secureboot/<SCHEMATIC>:<TALOS_VERSION>}}'
done
```

The patch has to be a strategic merge: these configs carry more than one document (the
per-node `HostnameConfig`), and `talosctl` rejects JSON patches against multi-document
configs. `--mode=no-reboot` makes Talos refuse the change rather than reboot; the install
image is only read at install and upgrade time, so it applies live. Add `--dry-run` first
to see the diff.

The bring-up scripts (`gen-talos-objects.sh`, `apply-config-all-nodes.sh`) are **not** an
upgrade path: `apply-config --insecure` only reaches nodes in maintenance mode, and a
changed `install.image` never reinstalls a running node.

## Upgrade Kubernetes

From any control-plane node — it upgrades the whole cluster:

```bash
talosctl -n 10.69.60.11 -e 10.69.60.11 --talosconfig talos/talosconfig upgrade-k8s --to <K8S_VERSION> --dry-run
talosctl -n 10.69.60.11 -e 10.69.60.11 --talosconfig talos/talosconfig upgrade-k8s --to <K8S_VERSION>
```

The dry run lists deprecated APIs still in use and the components it will change.
The real run pre-pulls images, rolls the API server, controller manager and scheduler one
control-plane node at a time, restarts every kubelet, then re-applies and prunes the
bootstrap manifests (CoreDNS; kube-proxy stays absent because it is disabled).

Then bump `--kubernetes-version` in `talos/gen-talos-objects.sh` and the Kubernetes row of
`versions.md`. Renovate does not track Kubernetes, so this is always a manual commit.

## Verify

```bash
kubectl get nodes -o wide                   # OS image and kubelet version on every node
talosctl -n 10.69.60.11,10.69.60.12,10.69.60.13 -e 10.69.60.11 --talosconfig talos/talosconfig etcd status
flux get ks; flux get hr -A
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl get ciliumbgpnodeconfigs            # every worker peering "established"
```

## Holding Kubernetes at 1.36

Talos 1.14 ships Kubernetes 1.37 as its default and supports it, but the cluster stays on
the latest 1.36 patch until the components that would carry the risk list 1.37 as
supported. As of October 2026:

| Component | 1.37 status |
| --- | --- |
| Cilium 1.20 (CNI, kube-proxy replacement, BGP) | Tested only through 1.36; 1.37 arrives with Cilium 1.21 |
| cert-manager 1.21 | Supports up to 1.36 |
| ceph-csi (via `ceph-csi-drivers`) | Matrix lists up to 1.36 |
| CloudNativePG 1.30 | "Tested, not supported" |
| Rook 1.21, Talos 1.14 | Supported |

Kubernetes 1.37 removes no GA or beta APIs. The change most likely to matter here is
`SELinuxMount` going GA: Talos runs SELinux, and pods that share a volume with different
SELinux labels can stall in `ContainerCreating`
([upstream notice](https://kubernetes.io/blog/2026/04/22/breaking-changes-in-selinux-volume-labeling/)).
Revisit once Cilium 1.21 is out and cert-manager lists 1.37, run `upgrade-k8s --dry-run`,
and check the `selinux_warning_controller_selinux_volume_conflict` metric before moving.

## Upgrade log

### 2026-10-10 — Talos 1.13.5 → 1.13.11 → 1.14.2, Kubernetes 1.36.2 → 1.36.5

The nodes had sat on 1.13.5 while Renovate bumped the pin; nobody had run an upgrade, and
this page still described regenerating and re-applying configs, which cannot upgrade a
running node.

| Step | Duration | Notes |
| --- | --- | --- |
| etcd snapshot | seconds | 2,555 keys, 88 MB |
| Each node → 1.13.11 | ~2 min upgrade + ~1 min for Ceph to settle | Control planes, then workers |
| Each node → 1.14.2 | ~1.5–2.5 min + ~0.5–1 min | 15 min for all six |
| `upgrade-k8s` → 1.36.5 | 6 min | Only manifest change: CoreDNS image and node affinity |
| `install.image` sync | seconds per node | No reboot |

What went wrong or was learned:

- **Worker drain failed** on the first worker: the run used `-e <worker>`, and `talosctl`
  could not fetch a kubeconfig from it to drain. The new image had been written but the
  node never rebooted, so nothing was disrupted; re-running with a control-plane endpoint
  worked. `upgrade-nodes.sh` now does this for every worker.
- **`talosctl upgrade` drains and uncordons on its own**, and waits for the node to be
  `Ready`; no manual cordon/uncordon is needed.
- **The default upgrade image is wrong** for these nodes (`metal-installer`, not
  `metal-installer-secureboot`); always pass `-i`.
- **The live `install.image` does not follow upgrades.** After both hops every node still
  named 1.13.5 until patched.
- **etcd moved to 3.7** with Talos 1.14; its metrics/health endpoints moved from port
  2379 to 2383. Nothing here scrapes them (`kubeEtcd` is disabled in the VictoriaMetrics
  stack), so nothing needed changing.
- Ceph stayed at all PGs `active+clean` between every node; with `noout` set, a reboot
  only degrades PGs briefly and no data moves.
