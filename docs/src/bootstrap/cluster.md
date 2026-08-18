# 3. Cilium + Flux

With the control plane bootstrapped ([Talos](./talos.md)), install Cilium so nodes go
`Ready`, then hand the cluster to Flux. Versions are in
[Reference → Versions](../reference/versions.md).

## Cilium

This bootstrap `helm install` mirrors the Flux-managed `HelmRelease`; once Flux takes
over it reconciles the same values plus the BGP resources under
`kubernetes/infrastructure/core/configs/cilium/`.

> Set `--version` to the **Cilium** version in
> [Reference → Versions](../reference/versions.md) — it must equal
> `spec.chart.spec.version` in
> `kubernetes/infrastructure/core/controllers/cilium/helm-release.yaml`.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium \
    --version <CILIUM_VERSION> \
    --namespace kube-system \
    --set ipam.mode=kubernetes \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set kubeProxyReplacement=true \
    --set bgpControlPlane.enabled=true \
    --set ingressController.enabled=true \
    --set ingressController.loadbalancerMode=dedicated \
    --set ingressController.default=true \
    --set prometheus.enabled=true \
    --set prometheus.metricsService=true \
    --set operator.prometheus.metricsService=true
```

## Flux

Pin the version (the **Flux** version in [Reference → Versions](../reference/versions.md))
for a reproducible install, and point `--path` at the cluster directory
(`kubernetes/clusters/main`), the entry point for the
[layered layout](../architecture.md#3-in-cluster-platform--flux-gitops).

> **Your local `flux` CLI version must match `--version`** (`flux version --client`).
> The committed `flux-system/gotk-components.yaml` is CLI-generated and
> version-specific, so bootstrapping with a mismatched CLI rewrites it. With a matching
> CLI, re-running `flux bootstrap` is a no-op (zero git diff).

```bash
flux bootstrap github \
  --version=<FLUX_VERSION> \
  --token-auth \
  --owner=Lil-Strudel \
  --repository=homelab \
  --branch=main \
  --path=kubernetes/clusters/main \
  --personal
```

Load the cluster Age key so Flux can decrypt SOPS secrets
([Operations → Secrets](../operations/secrets.md)). The `sops-age` secret is
referenced by the `infra-controllers`, `infra-configs`, and `apps` Kustomizations, so
it must exist before they reconcile:

```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/cluster.agekey
```

## Storage comes up automatically

From here Flux reconciles the whole platform — Cilium's BGP config, kube-vip, and the
Rook-Ceph operator, CSI drivers, and `CephCluster`. There is nothing to run by hand for
storage; a from-scratch bring-up gives Rook empty disks for free (the Talos install
leaves `/dev/nvme0n1` clean). Verify the storage tier and reach the dashboard in
[Operations → Storage](../operations/storage.md).
