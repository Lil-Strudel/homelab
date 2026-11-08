# Hackathon (temporary)

Infrastructure for the 2026 Cloud Native Hackathon app
([Lil-Strudel/2026-cn-hackathon](https://github.com/Lil-Strudel/2026-cn-hackathon)). **All of
it is temporary** and is built to come out cleanly: it lives in its own Flux Kustomizations,
its own namespaces and its own Terraform state, and nothing else in the cluster depends on it.

Because it is short-lived, its pinned versions are deliberately **not** in
[Reference → Versions](../reference/versions.md) and have no `customManagers` entries. The
`flux` Renovate manager still sees its HelmReleases.

Hubble was enabled for the hackathon but is permanent. See
[Observability → Network flows](./observability.md#network-flows-hubble).

## What runs

| Piece | Where | Role |
| --- | --- | --- |
| KEDA | `keda` | Scales the app's SSE fan-out pods on connected clients |
| ECK operator | `elastic-system` | Runs the app's Elasticsearch and Kibana. Manages the `cnh` namespace only. A 30-day trial license is enabled for ML features |
| Dash0 operator | `dash0-system` | Collects telemetry from the `cnh` namespace only (its only `Dash0Monitoring`), plus node-level metrics, and ships them to Dash0. Runs the read-only Agent0 connector |
| cloudflared | `cnh` | Outbound-only Cloudflare Tunnel publishing the app at `https://quikk.live`. No router change and no exposed home IP |
| The app | `cnh` | Pulled by Flux from a cosign-signed OCI artifact the app repo's CI publishes |

The Flux layout:

- `kubernetes/clusters/main/hackathon.yaml` has two Kustomizations:
  - `hackathon-controllers` installs the operators.
  - `hackathon-configs` sets up the tenant.
- `hackathon-configs` creates the `cnh` namespace and three things in it:
  - default-deny network policy, plus the platform allows
  - a `deployer` ServiceAccount whose Role is limited to `cnh`
  - the OCIRepository and Kustomization `app`
- **The app repo owns** everything that Kustomization applies: workloads, Elasticsearch, Redis, its own network policies and the ScaledObject.
- **This repo owns** the secrets (`app-secrets`, the tunnel token, the Dash0 token).

`hackathon-configs` uses `wait: false`. The `app` Kustomization it creates stays not-Ready
until CI publishes the first artifact, and waiting on it would hold the stage forever.

Flux reports the `app` Kustomization's result back to GitHub as a commit status on the deployed
commit, through the `github` notification Provider.

The public edge is `terraform/cnh/`, a separate root with state key `homelab/cnh.tfstate`. It
holds four things:

- the Cloudflare zone for `quikk.live`
- the registrar nameserver switch from Route53 Domains to Cloudflare
- the remotely-managed tunnel and its routes:
  - `/api/` → `api`
  - `/events/` → `fanout`
  - everything else → `web`
- the proxied CNAME

## Bring-up

1. Fill in the secrets with `sops <file>`:
   - `terraform/cnh/secrets.sops.yaml`: Cloudflare API token (Zone:Edit, DNS:Edit, Account › Cloudflare Tunnel:Edit) and account ID
   - `kubernetes/hackathon/controllers/dash0-operator/secret.sops.yaml`: Dash0 auth token
   - `kubernetes/hackathon/configs/cnh/app-secrets.sops.yaml`: OpenAI API key
   - `kubernetes/hackathon/configs/cnh/github-status.sops.yaml`: fine-grained PAT, commit statuses read/write on the app repo
2. Set the Dash0 `endpoint`, `apiEndpoint` and Agent0 `serverAddress` in
   `kubernetes/hackathon/controllers/dash0-operator/helm-release.yaml`.
3. Run `terraform -chdir=terraform/cnh init && terraform -chdir=terraform/cnh apply`, then copy the
   token in: `sops --set '["stringData"]["token"] "'"$(terraform -chdir=terraform/cnh output -raw tunnel_token)"'"' kubernetes/hackathon/configs/cloudflared/secret.sops.yaml`.
4. Push, then `flux reconcile kustomization hackathon-configs --with-source`.

## Teardown

Order matters. The Dash0 operator must still be running while its `Dash0Monitoring` resource
is deleted, or the finalizer strands the namespace.

1. **Remove the tenant.** Delete the `hackathon-configs` Kustomization from
   `kubernetes/clusters/main/hackathon.yaml` and push. Wait until `kubectl get ns cnh` returns
   NotFound. The Elasticsearch PVC is `ceph-block` with reclaim `Delete`, so its data goes too.
2. **Remove the operators.** Delete `kubernetes/clusters/main/hackathon.yaml` and
   `kubernetes/hackathon/`, then push. Flux uninstalls the HelmReleases and prunes the namespaces.
3. **Remove the CRDs**, which Helm leaves behind:
   ```bash
   kubectl get crd -o name | grep -E 'keda\.sh|k8s\.elastic\.co|dash0\.com' | xargs kubectl delete
   ```
4. **Remove the public edge.** Run `terraform -chdir=terraform/cnh destroy`, then delete `terraform/cnh/`.
   Destroying the registered-domain resource only drops it from state, so `quikk.live` keeps
   pointing at Cloudflare's nameservers until changed in Route53 Domains.
5. **Remove external accounts.** Delete the GHCR packages under the app repo, then revoke the Cloudflare, Dash0, OpenAI and GitHub tokens.
6. **Verify:**
   ```bash
   flux get kustomizations | grep hackathon        # nothing
   helm ls -A | grep -E 'keda|eck|dash0'          # nothing
   kubectl get ns cnh keda elastic-system dash0-system
   kubectl get crd | grep -E 'keda|elastic|dash0'  # nothing
   ```
