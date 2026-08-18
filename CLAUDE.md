# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Infrastructure-as-code for a home Kubernetes cluster and its network, declarative from bare metal up. Three independent domains: **Talos** (OS/cluster bootstrap), **Flux/Kubernetes** (in-cluster GitOps), and **Terraform** (MikroTik network). Full write-up: `docs/` (mdBook), published at https://lil-strudel.github.io/homelab/.

## Secrets: SOPS + Age

All secrets are SOPS-encrypted (`*.sops.yaml`); this repo is public. `.sops.yaml` at the root drives which recipients encrypt what, keyed by file path:
- `kubernetes/**` secrets → **admin + cluster** Age keys, and only `data`/`stringData` fields are encrypted (rest stays diffable). Flux decrypts in-cluster via the `sops-age` secret.
- `terraform/**` and `talos/**` secrets → **admin key only**.

The admin private key lives in `~/.config/sops/age/keys.txt` (also in a password manager). Encrypt/decrypt with `sops -e -i <file>` / `sops -d <file>`. Terraform reads secrets at plan time via the `sops` provider (`data.sops_file.secrets`); never write plaintext secrets to disk in tracked paths (`*.agekey`/`*.key`/`keys.txt` are gitignored).

## Talos (`talos/`)

Bootstraps the OS and Kubernetes control plane. Node layout: control plane `makima-1..3` at `10.69.60.11-13`, workers `rem-1..3` at `10.69.60.21-23`, control-plane VIP `10.69.60.10` (owned by kube-vip). Talos v1.13.6 / Kubernetes 1.36.2.

The committed source of truth is `secrets.sops.yaml` + `talosconfig.sops.yaml`. The plaintext `controlplane.yaml`/`worker.yaml`/`talosconfig` and per-node `machine-configs/` are **gitignored and regenerated** — never commit them.

Bring-up scripts (run from `talos/`, in order):
```
./gen-talos-objects.sh    # gen secrets + controlplane/worker/talosconfig from patch.yaml
./gen-machine-configs.sh  # patch base configs with per-node machine-patches/ → machine-configs/
./apply-config-all-nodes.sh   # talosctl apply-config to all 6 nodes
talosctl bootstrap  -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
talosctl kubeconfig -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
```
`danger-reset-all-nodes.sh` wipes and reboots every node — destructive.

Key `patch.yaml` invariants (do not change without understanding the fallout):
- **CNI is `none` and kube-proxy is `disabled`** — Cilium replaces both. Re-enabling either double-installs and breaks networking.
- Talos installs to the **Samsung SSD 870** (selected by `diskSelector.model`), deliberately *not* the NVMe, which is reserved for Ceph OSD data.
- The Kubernetes version is pinned twice and must stay in sync: `--kubernetes-version` in `gen-talos-objects.sh` and the Talos installer image tag in `patch.yaml`.

## Kubernetes / Flux (`kubernetes/`)

Flux GitOps, layered with explicit `dependsOn` ordering. Flux's entry point is
`kubernetes/clusters/main` (`--path` at bootstrap):

`clusters/main` → **core-controllers** → **core-configs** → **platform-controllers** →
**platform-configs** → **apps** (`apps/main`), each `dependsOn` the one before it.

`infrastructure/` is split into two tiers, each with two stages:

- **`core/`** — the primitives nothing else can run without. `core/controllers` installs
  Cilium, kube-vip, cert-manager, and the Rook operator + CSI drivers; `core/configs`
  applies what those define: Cilium BGP peering + LB IP pools, the `ClusterIssuer`s, and
  the Rook `CephCluster` with its StorageClasses.
- **`platform/`** — services built on the primitives, free to depend on storage and
  certificates. `platform/controllers` holds the observability stack, Velero, and ddns;
  `platform/configs` holds their `VMServiceScrape`s and `Ingress`es.

**The rule: a resource may depend on anything in its own stage or an earlier one, never a
later one.** Stage 1 of a tier installs things that provide APIs; stage 2 holds whatever
consumes them — *including HelmReleases*. The `CephCluster` is a HelmRelease in
`core/configs` because it needs the operator's CRDs, and that is the rule working, not an
exception. **A CR's CRD must come from a strictly earlier stage** — Flux dry-runs the whole
Kustomization, so one unknown `Kind` fails the dry-run and nothing in that stage applies.
Sharing a stage is only safe when the CRD already exists and just the backing is async (the
Loki `ObjectBucketClaim`). Depending on a later stage deadlocks rather than retries: every stage but the
last uses `wait: true`, so it never goes Ready and the stage it was waiting on never runs.

**Renaming or removing a Flux `Kustomization` prunes everything it owns.** Set
`deletionPolicy: Orphan` on the outgoing one, push it, verify it is live on the cluster,
and only then swap it out — see `docs/src/decisions/infrastructure-layering.md`.

- **Cilium** (`core/controllers/cilium/helm-release.yaml`) is CNI + kube-proxy replacement + default ingress controller + BGP control plane. Its Helm values must mirror the bootstrap `helm install` in `docs/src/bootstrap/cluster.md`, and the chart version must match what's used at bootstrap.
- **BGP** (`core/configs/cilium/bgp.yaml`): workers (non-control-plane nodes) peer ASN 65000 → MikroTik ASN 65100 at `10.69.60.1` to advertise LoadBalancer service IPs. kube-vip advertises the control-plane VIP separately.
- **Rook-Ceph** (`core/configs/rook-ceph/cluster.yaml`): OSDs consume `nvme0n1` (`deviceFilter: "^nvme0n1"`) on all nodes, tolerating control-plane taints.

There is no build/test tooling; changes are validated by Flux reconciliation. `flux reconcile kustomization <name> --with-source` forces a sync; the `flux`/`kubectl` CLIs operate against the live cluster.

### Adding a service to the cluster

Two things must both be right, or the service silently breaks or drifts:

1. **Dependency chain.** Decide which stage the manifest belongs to and register it so it reconciles in the right order:
   - A cluster primitive — networking, the VIP, certificates, storage → `infrastructure/core/controllers/<name>/`.
   - A resource those primitives define (`CiliumBGP*`, `ClusterIssuer`, `CephCluster`) → `infrastructure/core/configs/<name>/`.
   - A platform service that *uses* storage, certificates, or buckets → `infrastructure/platform/controllers/<name>/`.
   - A resource a platform service defines (`VMServiceScrape`), or an `Ingress` for one → `infrastructure/platform/configs/<name>/`.
   - Ordinary workloads → `apps/main/` (reconciles last).
   Every new directory must be listed in its parent `kustomization.yaml` — Flux only sees what Kustomize includes. Apply the rule above: a resource may depend on anything in its own stage or an earlier one, never a later one. Depending on a later stage **deadlocks** rather than retrying, because every stage but the last uses `wait: true`. If you need finer ordering than the stages give, add a `dependsOn` to the Kustomization in `clusters/main/`.

2. **Renovate coverage.** New pinned versions must be monitored, or they rot. Check that whatever you added is actually picked up:
   - **Flux-native sources** (`HelmRelease` chart versions, `HelmRepository`/`OCIRepository` refs, image tags in `kubernetes/**`) are covered automatically by the `flux` manager (`managerFilePatterns` matches `kubernetes/**.yaml`). Prefer these — they need no extra config.
   - **A version pinned anywhere else** (a raw manifest like `kube-vip.yaml`, a `--version` flag) is invisible to the standard managers and needs a `customManagers` regex entry in `renovate.json`. Follow the existing kube-vip/Cilium/Talos entries as the pattern.
   - **Version numbers in docs live in exactly one place: the `docs/src/reference/versions.md` table.** Every other doc uses a `<PLACEHOLDER>` and links there — never echo a pinned `x.y.z` into prose or a command elsewhere. Give the new component a table row and a `customManagers` entry that lists **both** its `versions.md` row (matched by ``ComponentName \| `(?<currentValue>…)` ``) **and** its real pin file, so Renovate bumps the table and the manifest together. `groupName` them (see `rook-ceph`, `cilium`) so the two land in one PR.
   - Add a `packageRules` `groupName` when a single component spans multiple packages (see `rook-ceph`, `cilium`) so its updates land in one PR. Major bumps for flux/custom managers already require dashboard approval — no per-service action needed.

## Comments vs. documentation

This repo deliberately keeps the two separate (see `docs/src/decisions/commenting.md`, the canonical rule). Apply it to anything you write here:

- **Inline comments are sparse** and earn their place only by explaining an unobvious **"why" about that exact line** — something the code can't say and a well-meaning cleanup would otherwise break. Keep them terse. Example: `disabled: true # Cilium is the kube-proxy replacement — do NOT re-enable`.
- **Do not** write inline comments that restate the next line, narrate structure/ordering, or read like documentation (provenance, version tables, rationale, how pieces fit together).
- **Everything documentation-shaped goes in `docs/`**, organized by topic: why a value is pinned/diverges → the relevant guide; how pieces relate → *Architecture*; conventions/addressing/naming → the *Plans*. When you change a value or workflow, update its guide there rather than annotating the source.

Before adding a comment, apply the test: is this an unobvious "why" about this exact line? If not, it's documentation — put it in `docs/`.

## Terraform (`terraform/`)

MikroTik RouterOS network as code (router, 2 switches, 2 access points) via the `terraform-routeros/routeros` provider, plus the Route53 IAM user for cert-manager and the split-horizon DNS records (internal MikroTik + public Route53). State in AWS S3 (`profile = "strudelan"`, native lockfile). AWS profiles resolve through **AWS SSO** — run `./scripts/aws_sso_setup.sh` once, then `aws sso login` before each session; then standard `terraform init/plan/apply` from `terraform/`.

- `main.tf` is the single root: it defines a **provider alias per device** (each MikroTik reached over its own `10.69.100.x:6729` HTTPS-API), the VLAN map, and instantiates reusable modules under `modules/` (`router`, `switch`, `access_point`, `wifi_config`, plus port/vlan helpers) with each device's port/VLAN assignments inline. Two AWS providers: the default (`strudelan`, state account) and `aws.dns` (`lil-strudel`, the account holding the `lilstrudel.io` Route53 zone). `route53.tf` uses `aws.dns` to manage the DNS IAM user + policy + key — see [DNS & Certificates](docs/src/operations/dns-and-certificates.md).
- The RouterOS API endpoint (port 6729, TLS) is set up out-of-band by `scripts/initialize_mikrotik.sh` (run once on a fresh device: DHCP, self-signed certs, enable `www-ssl`). `scripts/tf_import_mikrotik.sh` records `terraform import` commands for adopting pre-existing device state.
- Adding a device = add a provider alias + a module block; adding VLANs = edit the `vlans` local (a numeric ID map consumed by every module).

## Docs (`docs/`)

mdBook source, organized by job: **Overview** (`introduction`, `architecture` — the one home for system design), **Reference** (`reference/`: `systems`, `network`, `versions` — the single source of truth for pinned versions), **Bootstrap** (`bootstrap/`: ordered bring-up — `network` → `talos` → `cluster`), **Operations** (`operations/`: `secrets`, `storage`, `dns-and-certificates`, `adding-a-service`, `upgrades`), and **Decisions & Lessons** (`decisions/`: the "why" — `kube-vip`, `rook-ceph`, `commenting`). When changing a bootstrap workflow, update the matching runbook; when a value/version changes, update `reference/versions.md` (the one place numbers live — everything else links to it). Facts have a single home: design → `architecture`, versions → `reference/versions`, so don't restate them elsewhere.
