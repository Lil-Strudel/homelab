# Architecture

This is the one place the system *design* lives — how the three layers fit, how BGP
and storage are wired, and why. Other docs give commands and facts; when they need
the "how it fits together," they link here. Version numbers live in
[Reference → Versions](./reference/versions.md).

The whole homelab is declarative. Three layers, each owned by a different tool, each
committed to this repo:

```
        Terraform ──────────►  MikroTik network (VLANs, BGP, WiFi)
            │
            ▼
        Talos Linux ────────►  6× bare-metal nodes (immutable OS + k8s)
            │
            ▼
        Flux (GitOps) ──────►  in-cluster platform + workloads
```

## 1. Network — Terraform

The MikroTik router, switches, and access points are managed entirely by
[Terraform](https://www.terraform.io/) via the RouterOS provider. VLANs, trunk/access
ports, DHCP reservations, BGP peers, and WiFi are all code in [`terraform/`](https://github.com/Lil-Strudel/homelab/tree/main/terraform).
State lives in an encrypted, versioned AWS S3 bucket with native locking.

Because the provider needs LAN access and the SOPS Age key at apply time, applies run
with **Terraform Cloud execution = Local**.

See [Bootstrap → Network](./bootstrap/network.md) and [Reference → Network](./reference/network.md).

## 2. Operating system — Talos Linux

Every node runs [Talos](https://www.talos.dev/): a minimal, immutable, API-driven OS
with no shell. Machine configs are generated from encrypted secrets and per-node
patches in [`talos/`](https://github.com/Lil-Strudel/homelab/tree/main/talos), then
applied over the network. Talos bootstraps Kubernetes directly — no `kubeadm`, no
manual node prep.

- **Control plane** — `makima-1..3`
- **Workers** — `rem-1..3`
- Secure Boot enabled; the installer image is pinned in `talos/patch.yaml`.
- CNI and kube-proxy are disabled in Talos so Cilium can own both.
- The control-plane API VIP (`10.69.60.10`) is handled by **kube-vip** in BGP mode
  from the control-plane nodes (see platform below).

See [Bootstrap → Talos Cluster](./bootstrap/talos.md).

## 3. In-cluster platform — Flux GitOps

After bootstrap, [Flux](https://fluxcd.io/) reconciles everything under
[`kubernetes/`](https://github.com/Lil-Strudel/homelab/tree/main/kubernetes).
Git is the source of truth; changes land by commit.

The tree follows the standard Flux [monorepo layout](https://fluxcd.io/flux/guides/repository-structure/)
so ordering is explicit rather than a single flat apply:

```
kubernetes/
├── clusters/main/          # bootstrap entry point (--path)
│   ├── flux-system/        # gotk-components + gotk-sync (Flux itself)
│   ├── infrastructure.yaml # → the four infrastructure stages
│   └── apps.yaml           # → apps  (dependsOn platform-configs)
├── infrastructure/
│   ├── core/               # primitives: networking, VIP, certificates, storage
│   │   ├── controllers/    #   installs them (and their CRDs)
│   │   └── configs/        #   the resources those CRDs define
│   └── platform/           # services built on the primitives
│       ├── controllers/    #   observability, backups, ddns
│       └── configs/        #   scrapes and ingresses
└── apps/main/              # user-facing workloads
```

Each stage is its own Flux `Kustomization` wired with `dependsOn`, so a stage only
starts once the one before it is applied. Every stage but the last also uses
`wait: true`, meaning it isn't Ready until the HelmReleases inside it are healthy:

```
flux-system ─► core-controllers ─► core-configs ─► platform-controllers ─► platform-configs ─► apps
 (Flux)        (Cilium, kube-vip,   (BGP + LB pool,   (observability,        (scrapes,          (workloads)
                cert-manager,        ClusterIssuers,    Velero, ddns)        ingresses)
                Rook operator)       CephCluster+SCs)
```

**The single rule this encodes: a resource may depend on anything in its own stage or
an earlier one, never a later one.** Stage 1 of a tier installs the things that provide
APIs; stage 2 holds whatever needs them — *including HelmReleases*. The Rook
`CephCluster` is a HelmRelease and lives in `core/configs` because it consumes the
operator's CRDs, and that is the rule working, not a compromise.

The two tiers exist because one boundary was not enough. With a single
controllers/configs pair, everything that depended on anything landed in `configs`
regardless of what it was, and anything genuinely needing storage or certificates had
nowhere to go at all. Splitting core from platform gives those dependencies a home in
front of them. See
[Decisions → Infrastructure Layering](./decisions/infrastructure-layering.md), and
[adding a service](./operations/adding-a-service.md) for picking the stage.

| Component | Stage | Role |
| --- | --- | --- |
| **Cilium** | core-controllers | CNI + kube-proxy replacement + ingress controller + BGP service LB |
| **kube-vip** | core-controllers | Control-plane API VIP (`10.69.60.10`) over BGP |
| **cert-manager** | core-controllers | ACME (Let's Encrypt) certificate issuance + CRDs |
| **Rook-Ceph operator** | core-controllers | Ceph operator + ceph-csi-operator + CRDs |
| **Ceph-CSI drivers** | core-controllers | RBD/CephFS `Driver` CRs (dependsOn the operator) |
| **Cilium BGP / LB pool** | core-configs | `CiliumBGP*` + `CiliumLoadBalancerIPPool` (need Cilium CRDs) |
| **ClusterIssuers** | core-configs | `letsencrypt-staging` + `letsencrypt-prod` (need cert-manager CRDs) |
| **Rook `CephCluster`** | core-configs | The cluster CR, storage classes, and object store (need the operator) |
| **VictoriaMetrics / Loki / Grafana / Alloy** | platform-controllers | Metrics, logs, dashboards, log shipping |
| **Velero** | platform-controllers | Off-cluster PVC backups to S3 |
| **ddns** | platform-controllers | CronJob keeping Route53 pointed at the WAN address |
| **`VMServiceScrape`s** | platform-configs | Scrape targets for Ceph and Cilium (need the VM operator's CRDs) |
| **Ingresses** | platform-configs | Observability hostnames (need the ClusterIssuers from core) |

### Load balancing & the control-plane VIP

Two BGP speakers, split across node roles so they never collide on the same node
(only one BGP session per node IP can reach the router). Both peer as **AS 65000**
to the router at **AS 65100** (`10.69.60.1`).

- **Control-plane VIP** — `10.69.60.10`, advertised by **kube-vip** (BGP mode,
  `svc_enable=false`) from the **control-plane** nodes. Service LB is off here.
- **`LoadBalancer` service IPs** — advertised by **Cilium's BGP control plane** from
  the **worker** nodes (`nodeSelector` excludes control-plane). One pool,
  `services-pool`, covering `10.69.65.1`–`10.69.65.254`. That range is deliberately not
  a VLAN: it has no interface and no L2 segment, so it exists purely as the `/32`s
  advertised here and no host ever treats a service address as directly connected. See
  `kubernetes/infrastructure/core/configs/cilium/bgp.yaml` and `lb-pool.yaml`, and
  [Decisions → Service Networking](./decisions/service-networking.md) for the full
  reasoning and what it implies for firewall rules.

Cilium advertises **every** `LoadBalancer` service by default; label a Service
`bgp-advertise: "false"` to keep its IP off BGP. The router declares BGP peers for
all six nodes in `terraform/main.tf`.

Nothing is exposed to the internet. Whether a service faces the WAN is a single
declaration — the `expose` field on a service in `local.services` — not a property of the
address it holds.

See [Bootstrap → Network](./bootstrap/network.md) and [kube-vip Manifest](./decisions/kube-vip.md).

### Storage

Two tiers:

- **Rook-Ceph** (Ceph Tentacle) — replicated block/file storage backing cluster
  PersistentVolumes. Each of the six nodes contributes its 1 TB NVMe SSD as a single
  OSD (`deviceFilter: ^nvme0n1`): six OSDs, 3× replication, `host` failure domain.
  All three Ceph datastore types are enabled: `ceph-block` (RBD, the cluster default),
  `ceph-filesystem` (CephFS, RWX), and an RGW object store with `ceph-bucket` for
  `ObjectBucketClaim`s. The object store's data pool is **erasure-coded 2+1** rather than
  3× replicated, so bulk data costs 1.5× raw instead of 3×. See
  [Operations → Storage](./operations/storage.md).
- **Dell R730xd NAS** — separate bulk storage for media/backups, outside the cluster:
  8× 1 TB Samsung 870 across two ZFS pools, served over NFS.

PVC data is backed up off-cluster to AWS S3 by **Velero**; cluster state itself is
recovered from this repo via Flux. See [Operations → Backups](./operations/backups.md).

### Observability

Metrics (VictoriaMetrics), logs (Loki), log shipping (Grafana Alloy), and dashboards
(Grafana) each get their own namespace and HelmRelease, all in **`infrastructure/`**
rather than `apps/`: the stack watches the platform, so it has to reconcile before the
things it watches, and `apps` is the last layer. The scrape CRs it needs from other
namespaces live in `infrastructure/platform/configs/observability/`, after the operator that
defines them. See [Operations → Observability](./operations/observability.md).

## Secrets

Secrets never hit git in plaintext. Everything sensitive is [SOPS](https://github.com/getsops/sops)-encrypted
with [Age](https://github.com/FiloSottile/age), decrypted in place by Terraform, the
Talos config scripts, and Flux. See [Operations → Secrets](./operations/secrets.md).

## Current scope

The platform (Cilium, kube-vip, Rook-Ceph, cert-manager, Velero, observability) and four
user-facing workloads — Vaultwarden, Shlink, Minecraft, Factorio — run on the cluster.
Minecraft is a fleet rather than a single server: several worlds behind one router that
wakes them on demand and scales them back to zero when idle.
Their services are reachable from the Home and Management VLANs and over both WireGuard
tunnels ([firewall matrix](./reference/network.md#firewall)); nothing is exposed to the
internet. See [Operations → Applications](./operations/applications.md).
