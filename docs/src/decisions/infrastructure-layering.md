# Infrastructure Layering

`kubernetes/infrastructure/` is split into two tiers — **core** and **platform** — each
with a `controllers` and a `configs` stage, giving four ordered Flux `Kustomization`s.
The shape is in [Architecture](../architecture.md#3-in-cluster-platform--flux-gitops);
how to place a new manifest is in
[Adding a Service](../operations/adding-a-service.md). This page is the *why*.

## The rule

> A resource may depend on anything in **its own stage or an earlier one — never a
> later one.**

Everything else follows from that sentence.

## Why two tiers and not one

A single `controllers` → `configs` pair has exactly one slot for "this needs something
to exist first". So everything that depended on anything ended up in `configs`
regardless of what it actually was, and `configs` stopped meaning anything.

Worse, some dependencies had nowhere to go at all. `controllers` runs with
`wait: true`, so nothing in it is allowed to need something from `configs` — the stage
would never report Ready, `configs` would never reconcile, and the dependency would
never be satisfied. A workload needing a StorageClass, a certificate, or a bucket was
therefore unplaceable: too dependent for `controllers`, not a custom resource for
`configs`.

Splitting core from platform puts the primitives in front. Anything in `platform` may
freely depend on networking, certificates, and storage, because all three are finished
before it starts.

## A CRD must come from a *strictly earlier* stage

"Its own stage or earlier" has one sharp edge worth stating separately: **the CRD behind
a custom resource has to come from an earlier stage, never the same one.**

Flux dry-runs an entire `Kustomization` before applying any of it. One unknown `Kind`
fails the dry-run, and *nothing* in that stage is applied — not the offending resource,
not the twenty healthy ones beside it. A `ClusterImageCatalog` sitting next to the
CloudNativePG `HelmRelease` that installs its CRD takes the whole stage down with it:

```
Ready=False: ClusterImageCatalog/... dry-run failed:
  no matches for kind "ClusterImageCatalog" in version "postgresql.cnpg.io/v1"
```

Same-stage placement *is* fine when the CRD already exists and only the resource's
**backing** is asynchronous. Loki's `ObjectBucketClaim` sits beside its `HelmRelease` in
`platform/controllers` because the OBC CRD came from the Rook operator back in
`core-controllers`; the bucket takes a few seconds to provision and Loki simply retries.
The distinction is *"does the API exist yet"*, not *"is the thing ready yet"*.

## `configs` holds HelmReleases, and that is correct

The stage names describe **ordering**, not resource kinds. Stage 1 of a tier installs
things that provide APIs; stage 2 holds whatever consumes them. The Rook `CephCluster`
is a `HelmRelease` living in `core/configs` because it consumes the operator's CRDs —
that is the rule working exactly as intended, not an exception to it.

Read `configs` as "the part of this tier that needs the rest of this tier."

## Renaming a Kustomization is destructive by default

A Flux `Kustomization` owns an inventory. Delete the object and its finalizer garbage
collects everything in it — for `infra-controllers` that was Cilium, Rook, the
`CephCluster`, and every PVC behind them. Replacing stages in a single commit would
have taken the cluster with it, because Flux reconciles to the newest commit and would
never have observed the intermediate state.

The safe sequence is two commits, with a verified pause between them:

1. Set `deletionPolicy: Orphan` on the outgoing Kustomizations. Commit, push, and
   **confirm it is live on the cluster**:

   ```bash
   kubectl -n flux-system get kustomization <name> \
     -o jsonpath='{.spec.deletionPolicy}{"\n"}'
   ```

2. Only then move the directories and swap in the new Kustomizations. The outgoing
   ones orphan their inventories instead of pruning them, and the incoming ones adopt
   those resources on their next apply.

Flux also refuses to prune a resource that another `Kustomization` already owns, which
is a second line of defence — but it is not the one to rely on. Verify step 1 landed.

Keeping the rendered output identical across the move makes the change reviewable and
proves nothing was dropped:

```bash
diff <(kubectl kustomize <old-path>) <(kubectl kustomize <new-path>)
```
