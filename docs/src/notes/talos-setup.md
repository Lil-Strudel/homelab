# Talos Cluster Setup

Its quite easy :)

Get the latest secure boot iso from [talos factory](https://factory.talos.dev/?arch=amd64&board=undefined&cmdline-set=true&extensions=-&platform=metal&secureboot=true&target=metal)

> The control-plane VIP (`10.69.60.10`) is a Talos shared VIP, brought up by the OS once
> etcd is healthy — no temporary MikroTik redirect needed. During the very first
> bootstrap you talk to a real node IP (`10.69.60.11`) directly, as below.

Go into ./talos

run

```
./gen-talos-objects.sh
```

run

```
./gen-machine-configs.sh
```

Boot into the talos iso.

Enrol the Secure Boot keys on the boot page.

Boot into the talos iso again.

from the Talos directory run

```
talosctl apply-config --insecure -n 10.69.60.11 --file machine-configs/makima-1.yaml
```

on every machine. Or if talos is already installed on all machines and are all in maintanence mode

```
./apply-config-all-nodes.sh
```

once that is done doing its thing

```
talosctl bootstrap -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
```

```
talosctl kubeconfig -n 10.69.60.11 -e 10.69.60.11 --talosconfig=talos/talosconfig
```

Install cilium with helm

```
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install \
    cilium \
    cilium/cilium \
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
    --set ingressController.default=true
```

> This bootstrap install mirrors the Flux-managed `HelmRelease`; once Flux takes over it
> reconciles the same values plus the BGP `CiliumLoadBalancerIPPool` / `CiliumBGP*`
> resources under `kubernetes/main/kube-system/cilium/`.

Boostrap flux

```
flux bootstrap github \
  --token-auth \
  --owner=Lil-Strudel \
  --repository=homelab \
  --branch=main \
  --path=kubernetes/main \
  --personal
```

Load the cluster Age key so Flux can decrypt SOPS secrets (see
[Secrets with SOPS + Age](./secrets-with-sops.md)):

```
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/cluster.agekey
```
