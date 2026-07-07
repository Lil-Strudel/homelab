# Strudel Homelab

Infrastructure-as-code for my home Kubernetes cluster and the network it runs on —
declarative from bare metal up. Talos Linux for the OS, Terraform for the MikroTik
network, and Flux for everything inside the cluster.

📖 **Docs:** the full write-up lives in the [Strudel Homelab book](https://lil-strudel.github.io/homelab/)
(built from [`docs/`](./docs) with [mdBook](https://rust-lang.github.io/mdBook/)).

## Stack

| Layer | Tech |
| --- | --- |
| OS | [Talos Linux](https://www.talos.dev/) (secure-boot, immutable) |
| Kubernetes | `kubeadm`-free, bootstrapped by Talos |
| CNI | [Cilium](https://cilium.io/) (kube-proxy replacement, ingress) |
| Load balancing | [Cilium BGP](https://docs.cilium.io/en/stable/network/bgp-control-plane/) (service IPs, from workers) → MikroTik |
| Control-plane VIP | [kube-vip](https://kube-vip.io/) BGP (`10.69.60.10`, from control plane) |
| Storage | [Rook-Ceph](https://rook.io/) (in-cluster), Dell R730xd NAS (bulk) |
| GitOps | [Flux](https://fluxcd.io/) |
| Network IaC | [Terraform](https://www.terraform.io/) → [RouterOS](https://registry.terraform.io/providers/terraform-routeros/routeros/latest) |
| Secrets | [SOPS](https://github.com/getsops/sops) + [Age](https://github.com/FiloSottile/age) |
| TF state | AWS S3 (encrypted, versioned, native locking) |

## Repo layout

| Path | What |
| --- | --- |
| [`talos/`](./talos) | Talos machine configs, patches, and generation scripts |
| [`kubernetes/main/`](./kubernetes/main) | Flux-managed cluster state (Cilium, kube-vip, Rook-Ceph) |
| [`terraform/`](./terraform) | MikroTik network as code (router, switches, APs, VLANs) |
| [`scripts/`](./scripts) | MikroTik bootstrap + Terraform import helpers |
| [`docs/`](./docs) | This book's source |

## Hardware at a glance

- **Control plane** — 3× Dell OptiPlex Micro 7070 (`makima-1..3`)
- **Workers** — 3× Dell OptiPlex Micro 7080 (`rem-1..3`)
- **Network** — MikroTik CCR2004 router, CRS326 core + CRS312 10G switches, 2× cAPax APs
- **Storage / OOB** — Dell PowerEdge R730xd NAS, PiKVM, TESmart KVM, APC UPS

See [Systems](./docs/src/notes/systems-plan.md) and [Network](./docs/src/notes/network-plan.md)
for the full breakdown.

> ⚠️ This repo is public. All secrets are SOPS-encrypted; the plaintext Age keys and
> generated configs are gitignored. See [Secrets with SOPS + Age](./docs/src/notes/secrets-with-sops.md).
