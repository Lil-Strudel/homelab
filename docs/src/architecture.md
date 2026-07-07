# Architecture

The whole homelab is declarative. Three layers, each owned by a different tool, each
committed to this repo:

```
        Terraform ──────────►  MikroTik network (VLANs, BGP, WiFi)
            │
            ▼
        Talos Linux ────────►  6× bare-metal nodes (immutable OS + k8s)
            │
            ▼
        Flux (GitOps) ──────►  in-cluster platform (Cilium, kube-vip, Rook-Ceph)
```

## 1. Network — Terraform

The MikroTik router, switches, and access points are managed entirely by
[Terraform](https://www.terraform.io/) via the RouterOS provider. VLANs, trunk/access
ports, DHCP reservations, BGP peers, and WiFi are all code in [`terraform/`](https://github.com/Lil-Strudel/homelab/tree/main/terraform).
State lives in an encrypted, versioned AWS S3 bucket with native locking.

Because the provider needs LAN access and the SOPS Age key at apply time, applies run
with **Terraform Cloud execution = Local**.

See [Controlling MikroTik with Terraform](./notes/controlling-mikrotik-with-terraform.md)
and the [Network plan](./notes/network-plan.md).

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

See [Talos Cluster Setup](./notes/talos-setup.md).

## 3. In-cluster platform — Flux GitOps

After bootstrap, [Flux](https://fluxcd.io/) (v2.9.1) reconciles everything under
[`kubernetes/`](https://github.com/Lil-Strudel/homelab/tree/main/kubernetes).
Git is the source of truth; changes land by commit.

The tree follows the standard Flux [monorepo layout](https://fluxcd.io/flux/guides/repository-structure/)
so ordering is explicit rather than a single flat apply:

```
kubernetes/
├── clusters/main/          # bootstrap entry point (--path)
│   ├── flux-system/        # gotk-components + gotk-sync (Flux itself)
│   ├── infrastructure.yaml # → infra-controllers, then infra-configs
│   └── apps.yaml           # → apps  (dependsOn infra-configs)
├── infrastructure/
│   ├── controllers/        # CNI, operators, controllers (install CRDs)
│   └── configs/            # custom resources that use those CRDs
└── apps/main/              # user-facing workloads (none yet)
```

Each stage is its own Flux `Kustomization` wired with `dependsOn`, so a stage
only starts once the one it depends on is applied — and `infra-controllers` uses
`wait: true`, meaning it isn't considered Ready until its HelmReleases
(Cilium, Rook) are actually healthy:

```
flux-system ─► infra-controllers ─► infra-configs ─► apps
 (Flux)        (Cilium, kube-vip,    (Cilium BGP +    (workloads)
                Rook operator)        LB pool, Ceph
                                      cluster + SCs)
```

This is what lets, say, the Rook `CephCluster` (a config) reliably land *after*
the Rook operator and its CRDs (a controller), instead of racing it.

| Component | Stage | Role |
| --- | --- | --- |
| **Cilium** (1.19.5) | controllers | CNI + kube-proxy replacement + ingress controller + BGP service LB |
| **kube-vip** | controllers | Control-plane API VIP (`10.69.60.10`) over BGP |
| **Rook-Ceph operator** | controllers | Ceph operator + CSI + CRDs |
| **Cilium BGP / LB pool** | configs | `CiliumBGP*` + `CiliumLoadBalancerIPPool` (need Cilium CRDs) |
| **Rook `CephCluster`** | configs | The cluster CR + storage classes (need the operator) |

### Load balancing & the control-plane VIP

Two BGP speakers, split across node roles so they never collide on the same node
(only one BGP session per node IP can reach the router). Both peer as **AS 65000**
to the router at **AS 65100**.

- **Control-plane VIP** — `10.69.60.10`, advertised by **kube-vip** (BGP mode,
  `svc_enable=false`) from the **control-plane** nodes. Service LB is off here.
- **`LoadBalancer` service IPs** — advertised by **Cilium's BGP control plane** from
  the **worker** nodes (`nodeSelector` excludes control-plane). The pool is
  `10.69.255.0/24` — a dedicated, BGP-only range that belongs to no VLAN subnet
  (no DHCP, no connected route, no conflict). See
  `kubernetes/infrastructure/configs/cilium/bgp.yaml` and `lb-pool.yaml`.

The router declares BGP peers for all six nodes in `terraform/main.tf`.

See [MikroTik BGP Setup](./notes/mikrotik-setup-bgp.md).

### Storage

Two tiers:

- **Rook-Ceph** — replicated block/file storage backing cluster PersistentVolumes.
  Each of the six nodes contributes its 1 TB NVMe SSD as a single OSD
  (`deviceFilter: ^nvme0n1`): six OSDs, 3× replication, `host` failure domain.
- **Dell R730xd NAS** — separate bulk storage for media/backups, outside the cluster:
  8× 1 TB Samsung 870 across two ZFS pools, served over NFS.

## Secrets

Secrets never hit git in plaintext. Everything sensitive is [SOPS](https://github.com/getsops/sops)-encrypted
with [Age](https://github.com/FiloSottile/age), decrypted in place by Terraform, the
Talos config scripts, and Flux. See [Secrets with SOPS + Age](./notes/secrets-with-sops.md).

## Current scope

Today the cluster runs the **platform only** — Cilium, kube-vip, Rook-Ceph, and Flux.
User-facing workloads are not deployed yet.
