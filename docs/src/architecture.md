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
        Flux (GitOps) ──────►  in-cluster platform (Cilium, Rook-Ceph)
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
- The control-plane API VIP (`10.69.60.10`) is a **Talos shared VIP**, brought up
  at the OS layer (no kube-vip) — see `talos/machine-patches/controlplane-vip.yaml`.

See [Talos Cluster Setup](./notes/talos-setup.md).

## 3. In-cluster platform — Flux GitOps

After bootstrap, [Flux](https://fluxcd.io/) reconciles everything under
[`kubernetes/main/`](https://github.com/Lil-Strudel/homelab/tree/main/kubernetes/main).
Git is the source of truth; changes land by commit.

| Component | Role |
| --- | --- |
| **Cilium** | CNI + kube-proxy replacement + ingress controller + BGP service LB |
| **Rook-Ceph** | In-cluster distributed storage / PersistentVolumes |

(The control-plane API VIP is handled by Talos itself, not a Flux component — see above.)

### Load balancing & the control-plane VIP

Two separate mechanisms:

- **Control-plane VIP** — `10.69.60.10`, a **Talos shared VIP** on the Trusted VLAN.
  It's part of the OS, so it's up before Kubernetes and needs no BGP or ARP tricks.
- **`LoadBalancer` service IPs** — **Cilium's BGP control plane** advertises them to
  the MikroTik router. Control-plane nodes peer as **AS 65000** to the router at
  **AS 65100**, so service IPs route across the LAN as `/32`s. The pool is
  `10.69.255.0/24` — a dedicated, BGP-only range that belongs to no VLAN subnet
  (no DHCP, no connected route, no conflict). See
  `kubernetes/main/kube-system/cilium/bgp.yaml` and `lb-pool.yaml`.

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

Today the cluster runs the **platform only** — Cilium, Rook-Ceph, and Flux.
User-facing workloads are not deployed yet.
