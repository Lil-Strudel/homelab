# Adding a Service

Two things must both be right, or the service silently breaks or drifts: the
**dependency chain** (so it reconciles in the right order) and **Renovate coverage**
(so its pinned versions don't rot). The layering these build on is in
[Architecture → Flux GitOps](../architecture.md#3-in-cluster-platform--flux-gitops).

## 1. Pick the layer

Decide which layer the manifest belongs to and register it in that layer's
`kustomization.yaml` — Flux only sees what Kustomize includes.

| The manifest is… | Goes in | Reconciles |
| --- | --- | --- |
| An operator / CRD-provider / HelmRelease others depend on | `infrastructure/controllers/<name>/` | first |
| A custom resource of an operator (references a CRD) | `infrastructure/configs/<name>/` | after controllers |
| An ordinary workload | `apps/main/` | last |

Configs reconcile *after* controllers, so their CRDs exist by then. If a resource needs
something from an earlier layer (a CRD, a secret, an operator), confirm that layer's
Kustomization owns it. For finer ordering than the three layers give, add a `dependsOn`
to the Kustomization in `clusters/main/`.

## 2. Confirm Renovate coverage

New pinned versions must be monitored or they rot. Check that what you added is picked
up (and record it in [Reference → Versions](../reference/versions.md) if it's a
platform pin):

- **Flux-native sources** — `HelmRelease` chart versions, `HelmRepository`/
  `OCIRepository` refs, and image tags in `kubernetes/**` — are covered automatically
  by the `flux` manager. Prefer these; they need no extra config.
- **A version pinned anywhere else** — a raw manifest, a version echoed in `docs/`, a
  `--version` flag in a setup guide — is invisible to the standard managers and needs a
  `customManagers` regex entry in `renovate.json` (follow the kube-vip / Cilium / Talos
  entries). When the same version is duplicated across files, list **every** file in
  that manager's `managerFilePatterns` so they update together.
- Add a `packageRules` `groupName` when one component spans multiple packages (see
  `rook-ceph`, `cilium`) so its updates land in one PR.

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
