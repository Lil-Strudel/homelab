# Adding a Service

Two things must both be right, or the service silently breaks or drifts: the
**dependency chain** (so it reconciles in the right order) and **Renovate coverage**
(so its pinned versions don't rot). The layering these build on is in
[Architecture → Flux GitOps](../architecture.md#3-in-cluster-platform--flux-gitops).

## 1. Pick the stage

Decide which stage the manifest belongs to and register it in that stage's
`kustomization.yaml` — Flux only sees what Kustomize includes.

| The manifest is… | Goes in | Reconciles |
| --- | --- | --- |
| A cluster primitive — networking, the VIP, certificates, storage | `infrastructure/core/controllers/<name>/` | 1st |
| A resource those primitives define (`CiliumBGP*`, `ClusterIssuer`, `CephCluster`) | `infrastructure/core/configs/<name>/` | 2nd |
| A platform service that *uses* storage, certificates, or buckets | `infrastructure/platform/controllers/<name>/` | 3rd |
| A resource a platform service defines (`VMServiceScrape`), or an `Ingress` for one | `infrastructure/platform/configs/<name>/` | 4th |
| An ordinary workload | `apps/main/` | last |

The rule behind the table: **a resource may depend on anything in its own stage or an
earlier one, never a later one.** So a `HelmRelease` that needs a StorageClass goes in
`platform/controllers`, *after* `core/configs` creates it — and a `HelmRelease` that
needs the Rook operator's CRDs goes in `core/configs`, which is why that stage holds
HelmReleases and not only custom resources. See
[Decisions → Infrastructure Layering](../decisions/infrastructure-layering.md).

**A custom resource must be at least one stage behind the thing that installs its CRD.**
Flux dry-runs a whole `Kustomization` before applying any of it, so one unknown `Kind`
fails the dry-run and nothing in that stage is applied. Placing a CR beside the
`HelmRelease` that defines it takes down every other resource in the stage. Sharing a
stage is only safe when the CRD already exists and merely the *backing* is async — Loki's
`ObjectBucketClaim` sits beside its `HelmRelease` because the OBC CRD came from Rook two
stages earlier.

Depending on a *later* stage does not merely retry — it deadlocks. Every stage but the
last runs with `wait: true`, so a workload in `core/controllers` that waits on something
from `core/configs` never goes Ready, `core/configs` never reconciles, and the thing it
was waiting for is never created. If you need finer ordering than the stages give, add a
`dependsOn` to the Kustomization in `clusters/main/`.

> **A scrape CR for your own app belongs with the app, not in `platform/configs/observability/`.**
>
> The rule above is about *CRDs*, and a `VMServiceScrape` satisfies it either way — the
> VictoriaMetrics operator installs its CRDs in `platform/controllers`. What matters is the
> **namespace**. The existing scrapes live in `platform/configs/` because they target
> `rook-ceph` and `kube-system`, namespaces earlier stages already created. A scrape
> targeting a namespace that *your app* creates cannot go there: it reconciles before
> `apps`, the namespace does not exist yet, and the failed apply takes the whole
> `platform-configs` Kustomization — and therefore every app behind it — down with it.

## 2. Confirm Renovate coverage

New pinned versions must be monitored or they rot. Check that what you added is picked
up (and record it in [Reference → Versions](../reference/versions.md) if it's a
platform pin):

- **Flux-native sources** — `HelmRelease` chart versions and `HelmRepository`/
  `OCIRepository` refs — are covered automatically by the `flux` manager. Prefer these;
  they need no extra config.
- **Container `image:` tags in ordinary workload manifests** under `kubernetes/apps/`
  (a plain `Deployment`, `StatefulSet`, etc.) are covered by the `kubernetes` manager,
  scoped to that path in `renovate.json`. The `flux` manager only reads Flux CRDs, so an
  image tag pinned inside a `HelmRelease`'s `values` (see the velero-plugin / Ceph image
  entries) still needs a `customManagers` regex.
- **A version pinned anywhere else** — a raw manifest, a version echoed in `docs/`, a
  `--version` flag in a setup guide — is invisible to the standard managers and needs a
  `customManagers` regex entry in `renovate.json` (follow the kube-vip / Cilium / Talos
  entries). When the same version is duplicated across files, list **every** file in
  that manager's `managerFilePatterns` so they update together.
- Add a `packageRules` `groupName` when one component spans multiple packages (see
  `rook-ceph`, `cilium`) so its updates land in one PR.

## Networking: IP, DNS & exposure

A service reachable by hostname needs a **pinned** LoadBalancer IP and a DNS record. All
service IPs come from one pool, `services-pool` (`10.69.65.1`–`10.69.65.254`); the address
carries no exposure meaning (see
[Decisions → Service Networking](../decisions/service-networking.md)).

1. **Claim an address** by reading `local.services` in `terraform/main.tf` — the
   allocation record — and taking a free one.

2. **Pin it** on the `LoadBalancer` Service — or, for a dedicated-mode `Ingress`, on
   the `Ingress` (Cilium propagates `lbipam.cilium.io/*` to the generated Service):

   ```yaml
   metadata:
     annotations:
       lbipam.cilium.io/ips: "10.69.65.50"
   ```

3. **Register DNS** by adding the service to the same `services` map (one source of truth
   for both horizons) and `terraform apply`:

   ```hcl
   services = {
     "myapp.lilstrudel.io" = { ip = "10.69.65.50", zone = local.domain, expose = null }
   }
   ```

   Entries are keyed by FQDN, so a service can take a subdomain of any zone listed in
   `local.zones` — or a bare apex, if it should own the whole domain. `expose` is the
   single internet-facing switch; `null` keeps the service internal. See
   [DNS & Certificates](./dns-and-certificates.md).

4. **Certificate** — reference `letsencrypt-prod` (DNS-01, no inbound needed). A trusted
   cert works even for internal-only services.

**Anything speaking HTTP goes behind an `Ingress`, never a raw `LoadBalancer`.** Keep the
workload's own Service `ClusterIP`, put the pinned IP and the `cert-manager` annotation on
the `Ingress`, and let it terminate TLS; in-cluster callers keep using the `ClusterIP`
Service over cluster DNS. Internal-only is not a reason to skip this — DNS-01 issues
without any inbound path, so plaintext buys nothing. Only a non-HTTP protocol, which an
`Ingress` cannot carry, justifies exposing a `LoadBalancer` directly: Minecraft and
Factorio on their game ports, `alloy-syslog` on UDP 514.

An `Ingress` naming a `ClusterIssuer` belongs in `infrastructure/platform/` or `apps/` —
never `infrastructure/core/controllers/`, which reconciles before the issuers exist.

## Hardening

A workload in `apps/main/` is expected to match the baseline the existing apps run —
non-root, dropped capabilities, `RuntimeDefault` seccomp, no service-account token, a
namespace enforcing PSA `restricted`, and a default-deny `CiliumNetworkPolicy` with the
flows it actually needs written back in. See [Applications](./applications.md).

## Secrets

To add an application secret: write a normal `Secret` manifest named
`something.sops.yaml` under `kubernetes/apps/` (or `kubernetes/infrastructure/`),
encrypt it with `sops -e -i something.sops.yaml` (only `data`/`stringData` get
encrypted, so the rest stays diffable), add it to the relevant `kustomization.yaml`,
and commit. The owning Kustomization decrypts it on apply. See
[Secrets](./secrets.md).

## Force a sync

Changes land on commit, but to reconcile immediately:

```bash
flux reconcile kustomization <name> --with-source
```
